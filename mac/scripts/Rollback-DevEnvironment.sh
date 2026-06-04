#!/bin/bash
# Rollback script — uninstalls packages recorded in the manifest.
# Runs as root. Reads /Library/MasterElectronics/DevSetup/manifest.json
# and removes each package that was installed by the installer.
#
# Usage: sudo bash Rollback-DevEnvironment.sh [--dry-run]

set -uo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

ROOT="/Library/MasterElectronics"
MANIFEST="$ROOT/DevSetup/manifest.json"
LOG_DIR="$ROOT/Logs"
ROLLBACK_LOG="$LOG_DIR/rollback-$(date '+%Y%m%d-%H%M%S').log"
NPM_GLOBAL="$ROOT/npm"
NVM_DIR="$ROOT/nvm"

BREW_PREFIX=$([ "$(uname -m)" = "arm64" ] && echo "/opt/homebrew" || echo "/usr/local")
BREW="$BREW_PREFIX/bin/brew"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$ROLLBACK_LOG"; }
dry() { $DRY_RUN && log "[DRY-RUN] Would: $*" || true; }

if $DRY_RUN; then
    log "DRY-RUN mode — no changes will be made."
fi

if [ ! -f "$MANIFEST" ]; then
    log "ERROR: Manifest not found at $MANIFEST — cannot roll back."
    exit 1
fi

log "Reading manifest: $MANIFEST"

# ── Parse manifest entries (no jq dependency) ─────────────────────────────────
# Extract name/status/method pairs using python3 (available via bundled install)
ENTRIES=$(python3 -c "
import json, sys
data = json.load(open('$MANIFEST'))
for p in data.get('Packages', []):
    if p.get('status') == 'installed':
        print(p['name'] + '|' + p.get('method','unknown'))
" 2>/dev/null)

if [ -z "$ENTRIES" ]; then
    log "No installed packages found in manifest."
    exit 0
fi

log "Packages to remove:"
echo "$ENTRIES" | while IFS='|' read -r name method; do
    log "  - $name (installed via $method)"
done

# ── Remove functions ───────────────────────────────────────────────────────────
remove_app() {
    local app_path="$1"
    if [ -d "$app_path" ]; then
        if $DRY_RUN; then dry "rm -rf \"$app_path\""; else
            log "Removing $app_path..."
            rm -rf "$app_path"
            log "  Removed."
        fi
    else
        log "  $app_path not found — already removed."
    fi
}

remove_binary() {
    local bin_path="$1"
    if [ -f "$bin_path" ]; then
        if $DRY_RUN; then dry "rm -f \"$bin_path\""; else
            log "Removing $bin_path..."
            rm -f "$bin_path"
        fi
    fi
}

brew_uninstall() {
    local formula="$1" is_cask="${2:-true}"
    if [ ! -x "$BREW" ]; then log "brew not found — skipping uninstall of $formula"; return; fi
    local CONSOLE_USER
    CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
    if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
        CONSOLE_USER=$(dscl . -list /Users UniqueID 2>/dev/null | \
            awk '$2 >= 500 && $2 < 60000 {print $1}' | grep -v '^_' | head -1)
    fi
    if $DRY_RUN; then dry "brew uninstall $formula as $CONSOLE_USER"; return; fi
    if [ "$is_cask" = "true" ]; then
        sudo -u "$CONSOLE_USER" "$BREW" uninstall --cask "$formula" 2>/dev/null || \
            log "  brew cask uninstall $formula failed (may already be removed)"
    else
        sudo -u "$CONSOLE_USER" "$BREW" uninstall "$formula" 2>/dev/null || \
            log "  brew uninstall $formula failed (may already be removed)"
    fi
}

# ── Process each package ───────────────────────────────────────────────────────
echo "$ENTRIES" | while IFS='|' read -r name method; do
    log "--- Rolling back: $name (method: $method) ---"
    case "$name" in
        "VS Code")
            remove_app "/Applications/Visual Studio Code.app"
            remove_binary "/usr/local/bin/code"
            remove_binary "$BREW_PREFIX/bin/code"
            log "VS Code rolled back."
            ;;
        "Git")
            # Git is part of Xcode CLT — do not remove CLT as it affects other tools
            log "Git: installed via Xcode CLT — skipping removal (CLT removal is too destructive)."
            ;;
        "PowerShell 7")
            case "$method" in
                bundled|direct)
                    if pkgutil --pkg-info com.microsoft.powershell &>/dev/null; then
                        if $DRY_RUN; then dry "pkgutil --forget com.microsoft.powershell + rm /usr/local/bin/pwsh"; else
                            pkgutil --forget com.microsoft.powershell 2>/dev/null || true
                            remove_binary /usr/local/bin/pwsh
                            remove_app "/Applications/PowerShell.app"
                        fi
                    else
                        log "  PowerShell 7 pkg not registered — removing binary."
                        remove_binary /usr/local/bin/pwsh
                    fi
                    ;;
                brew) brew_uninstall "powershell" ;;
                *) log "  Unknown method $method — skipping PowerShell 7 removal." ;;
            esac
            log "PowerShell 7 rolled back."
            ;;
        "Python 3.12")
            case "$method" in
                bundled|direct)
                    if $DRY_RUN; then dry "pkgutil --forget org.python.Python.PythonFramework-3.12 + rm /usr/local/bin/python3.12"; else
                        pkgutil --forget "org.python.Python.PythonFramework-3.12" 2>/dev/null || true
                        remove_binary /usr/local/bin/python3.12
                        remove_binary /usr/local/bin/pip3.12
                        rm -rf "/Library/Frameworks/Python.framework/Versions/3.12" 2>/dev/null || true
                        rm -rf "/Applications/Python 3.12" 2>/dev/null || true
                    fi
                    ;;
                brew) brew_uninstall "python@3.12" false ;;
                *) log "  Unknown method $method — skipping Python 3.12 removal." ;;
            esac
            log "Python 3.12 rolled back."
            ;;
        "AWS CLI v2")
            case "$method" in
                bundled|direct)
                    if $DRY_RUN; then dry "pkgutil --forget com.amazon.aws.cli2 + rm /usr/local/bin/aws"; else
                        pkgutil --forget "com.amazon.aws.cli2" 2>/dev/null || true
                        remove_binary /usr/local/bin/aws
                        remove_binary /usr/local/bin/aws_completer
                        rm -rf /usr/local/aws-cli 2>/dev/null || true
                    fi
                    ;;
                brew) brew_uninstall "awscli" false ;;
                *) log "  Unknown method $method — skipping AWS CLI removal." ;;
            esac
            log "AWS CLI v2 rolled back."
            ;;
        "GitHub CLI")
            case "$method" in
                bundled|direct)
                    remove_binary /usr/local/bin/gh
                    ;;
                brew) brew_uninstall "gh" false ;;
                *) log "  Unknown method $method — skipping GitHub CLI removal." ;;
            esac
            log "GitHub CLI rolled back."
            ;;
        "Terraform")
            case "$method" in
                bundled|direct)
                    remove_binary /usr/local/bin/terraform
                    ;;
                brew) brew_uninstall "terraform" false ;;
                *) log "  Unknown method $method — skipping Terraform removal." ;;
            esac
            log "Terraform rolled back."
            ;;
        "Docker Desktop")
            case "$method" in
                bundled|direct|brew)
                    if $DRY_RUN; then dry "rm -rf /Applications/Docker.app + cleanup"; else
                        # Quit Docker if running
                        osascript -e 'quit app "Docker"' 2>/dev/null || true
                        sleep 2
                        remove_app "/Applications/Docker.app"
                        # Docker config lives in each user's home, not root's ($HOME=/var/root here).
                        for user_home in /Users/*/; do
                            rm -rf "$user_home/.docker" 2>/dev/null || true
                            rm -rf "$user_home/Library/Application Support/Docker" 2>/dev/null || true
                        done
                        rm -rf "/Library/Application Support/com.docker.docker" 2>/dev/null || true
                        rm -f /usr/local/bin/docker /usr/local/bin/docker-compose 2>/dev/null || true
                    fi
                    ;;
            esac
            log "Docker Desktop rolled back."
            ;;
        "nvm")
            if $DRY_RUN; then dry "rm -rf $NVM_DIR"; else
                rm -rf "$NVM_DIR"
                log "nvm directory removed: $NVM_DIR"
            fi
            ;;
        "Node.js")
            case "$method" in
                bundled)
                    if $DRY_RUN; then dry "pkgutil --forget org.nodejs.node + remove node/npm binaries"; else
                        pkgutil --forget "org.nodejs.node" 2>/dev/null || true
                        remove_binary /usr/local/bin/node
                        remove_binary /usr/local/bin/npm
                        remove_binary /usr/local/bin/npx
                    fi
                    ;;
                direct)
                    # Installed via nvm — nvm removal above handles this
                    log "  Node installed via nvm — covered by nvm rollback."
                    ;;
            esac
            log "Node.js rolled back."
            ;;
        "Claude Code")
            if $DRY_RUN; then dry "rm -f /usr/local/bin/claude + per-user ~/.local/{bin,share}/claude + legacy npm copies"; else
                # Native install (current): machine-wide binary + per-user data dir
                rm -f /usr/local/bin/claude 2>/dev/null || true
                for user_home in /Users/*/; do
                    rm -f "$user_home/.local/bin/claude" 2>/dev/null || true
                    rm -rf "$user_home/.local/share/claude" 2>/dev/null || true
                done
                # Legacy npm install (older deployments / removed install path)
                rm -f "$NPM_GLOBAL/bin/claude" "$NPM_GLOBAL/bin/claude-code" 2>/dev/null || true
                rm -rf "$NPM_GLOBAL/lib/node_modules/@anthropic-ai" 2>/dev/null || true
                rm -rf "$NPM_GLOBAL/lib/node_modules/@anthropic" 2>/dev/null || true
                log "Claude Code removed (native binary + per-user data + any legacy npm copy)."
            fi
            ;;
        "Claude Desktop")
            case "$method" in
                bundled|direct|brew)
                    if $DRY_RUN; then dry "rm -rf /Applications/Claude.app"; else
                        osascript -e 'quit app "Claude"' 2>/dev/null || true
                        sleep 1
                        remove_app "/Applications/Claude.app"
                        # Per-user config lives in each user's home, not root's.
                        for user_home in /Users/*/; do
                            rm -rf "$user_home/Library/Application Support/Claude" 2>/dev/null || true
                        done
                    fi
                    ;;
            esac
            log "Claude Desktop rolled back."
            ;;
        *)
            log "Unknown package '$name' — skipping."
            ;;
    esac
done

# ── Clean up MasterElectronics directories ────────────────────────────────────
if ! $DRY_RUN; then
    log "Cleaning up $NPM_GLOBAL..."
    rm -rf "$NPM_GLOBAL" 2>/dev/null || true
    log "Cleaning up $ROOT/DevSetup and $ROOT/Temp..."
    rm -rf "$ROOT/DevSetup" "$ROOT/Temp" 2>/dev/null || true
    rm -f "$ROOT/verify-install.log" "$ROOT/verify-configure.log" 2>/dev/null || true

    # Remove shell profile block from all user profiles
    for user_home in /Users/*/; do
        for rc in "$user_home/.zshrc" "$user_home/.bash_profile"; do
            if [ -f "$rc" ] && grep -q "Master Electronics Dev Setup" "$rc"; then
                sed -i '' '/# === Master Electronics Dev Setup ===/,/# === End Master Electronics Dev Setup ===/d' "$rc" 2>/dev/null || true
                log "Removed shell profile block from $rc"
            fi
        done
        # Remove configured marker
        rm -f "$user_home/.claude/.devsetup-configured" 2>/dev/null || true
    done
fi

log "Rollback complete."
$DRY_RUN && log "(DRY-RUN — no actual changes were made)"
