#!/bin/bash
# Tier 3 — Installer (lives inside mac-setup-automation.zip)
# Runs as root via Deploy-DevEnvironment.sh.
# Installs all developer tools on the target Mac, then configures user profiles.
#
# Install tiers per package (in order):
#   Tier 1: Bundled .pkg/.zip in bundled/ — offline, no network
#   Tier 2: Direct download from vendor URL
#   Tier 3: Homebrew cask (runs as $CONSOLE_USER — brew rejects root)
#   Tier 4: Homebrew formula (last resort)

set -uo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(dirname "$SCRIPT_DIR")"
BUNDLED_DIR="$PKG_ROOT/bundled"

ROOT="/Library/MasterElectronics"
DEV_SETUP_DIR="$ROOT/DevSetup"
TEMP_DIR="$ROOT/Temp"
LOG_DIR="$ROOT/Logs"
INSTALL_LOG="$DEV_SETUP_DIR/install.log"
MANIFEST="$DEV_SETUP_DIR/manifest.json"
VERIFY_INSTALL="$ROOT/verify-install.log"

mkdir -p "$DEV_SETUP_DIR" "$TEMP_DIR" "$LOG_DIR"

# ── Console user (brew must run as non-root) ───────────────────────────────────
if [ -z "${CONSOLE_USER:-}" ] || [ "$CONSOLE_USER" = "root" ]; then
    CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
fi
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    CONSOLE_USER=$(dscl . -list /Users UniqueID 2>/dev/null | \
        awk '$2 >= 500 && $2 < 60000 {print $1}' | grep -v '^_' | head -1)
fi
CONSOLE_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
CONSOLE_HOME="${CONSOLE_HOME:-/Users/$CONSOLE_USER}"

# Homebrew prefix — detect arch
if [ "$(uname -m)" = "arm64" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
BREW="$BREW_PREFIX/bin/brew"

# npm global prefix — system-wide (matches Windows C:\ProgramData\npm pattern)
NPM_GLOBAL="/Library/MasterElectronics/npm"
mkdir -p "$NPM_GLOBAL/bin"

# ── Logging ────────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')][$level] $*"
    echo "$msg" | tee -a "$INSTALL_LOG"
}
log_ok()   { log "OK  " "$@"; }
log_warn() { log "WARN" "$@"; }
log_fail() { log "FAIL" "$@"; }
log_info() { log "INFO" "$@"; }

# ── Manifest helpers ───────────────────────────────────────────────────────────
MANIFEST_ENTRIES="[]"
manifest_record() {
    local name="$1" status="$2" method="$3"
    # Append JSON entry (simple string concat — no jq dependency at this stage)
    MANIFEST_ENTRIES="${MANIFEST_ENTRIES%]},{\"name\":\"$name\",\"status\":\"$status\",\"method\":\"$method\"}]"
    MANIFEST_ENTRIES="${MANIFEST_ENTRIES/\[\,/[}"
}

# ── Helper: run command with timeout ──────────────────────────────────────────
invoke_with_timeout() {
    local timeout_secs="$1"; shift
    timeout "$timeout_secs" "$@"
    local exit_code=$?
    [ $exit_code -eq 124 ] && { log_warn "Command timed out after ${timeout_secs}s: $*"; return 124; }
    return $exit_code
}

# ── Helper: install .pkg file ─────────────────────────────────────────────────
install_pkg() {
    local pkg_path="$1"
    log_info "Installing PKG: $pkg_path"
    invoke_with_timeout 600 installer -pkg "$pkg_path" -target / -verboseR 2>&1 | \
        tail -5 | while read -r line; do log_info "  PKG: $line"; done
    local rc=${PIPESTATUS[0]}
    return $rc
}

# ── Helper: install .dmg (copy .app to /Applications) ────────────────────────
install_dmg() {
    local dmg_path="$1" app_name="$2"
    local mount_point="$TEMP_DIR/dmg_mount_$$"
    log_info "Mounting DMG: $dmg_path"
    mkdir -p "$mount_point"
    if ! invoke_with_timeout 60 hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse -quiet -noquarantine; then
        log_warn "Failed to mount $dmg_path"
        return 1
    fi
    local src_app
    src_app=$(find "$mount_point" -maxdepth 2 -name "$app_name" 2>/dev/null | head -1)
    if [ -z "$src_app" ]; then
        hdiutil detach "$mount_point" -quiet 2>/dev/null
        log_warn "Could not find $app_name in DMG."
        return 1
    fi
    cp -R "$src_app" /Applications/
    # Strip the Gatekeeper quarantine flag so the app opens without prompting.
    xattr -r -d com.apple.quarantine "/Applications/$app_name" 2>/dev/null || true
    hdiutil detach "$mount_point" -quiet 2>/dev/null
    rm -rf "$mount_point"
    log_info "Copied $app_name to /Applications/"
    return 0
}

# ── Helper: run brew as console user ─────────────────────────────────────────
brew_install() {
    local cask_or_pkg="$1" is_cask="${2:-true}"
    if [ ! -x "$BREW" ]; then
        log_warn "Homebrew not found at $BREW — skipping brew install for $cask_or_pkg"
        return 1
    fi
    if [ "$is_cask" = "true" ]; then
        sudo -u "$CONSOLE_USER" "$BREW" install --cask "$cask_or_pkg" 2>&1 | \
            tail -5 | while read -r line; do log_info "  brew: $line"; done
    else
        sudo -u "$CONSOLE_USER" "$BREW" install "$cask_or_pkg" 2>&1 | \
            tail -5 | while read -r line; do log_info "  brew: $line"; done
    fi
    local rc=${PIPESTATUS[0]}
    return $rc
}

# ── Helper: verify command exists on PATH ─────────────────────────────────────
verify_cmd() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null || \
    [ -x "$BREW_PREFIX/bin/$cmd" ] || \
    [ -x "$NPM_GLOBAL/bin/$cmd" ]
}

# ── Helper: verify .app bundle exists ────────────────────────────────────────
verify_app() {
    local app_path="$1"
    [ -d "$app_path" ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTALL FUNCTIONS — one per tool
# ═══════════════════════════════════════════════════════════════════════════════

install_homebrew() {
    log_info "=== Homebrew ==="
    if [ -x "$BREW" ]; then
        log_ok "Homebrew already installed at $BREW — skipping."
        return 0
    fi
    log_info "Installing Homebrew as $CONSOLE_USER..."
    local install_script="$TEMP_DIR/brew-install.sh"
    if ! curl -fsSL 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' -o "$install_script"; then
        log_warn "Could not download Homebrew install script."
        return 1
    fi
    chmod +x "$install_script"
    # sudo resets the environment (env_reset), so NONINTERACTIVE must be set via
    # `env` inside the sudo target or Homebrew's license prompt hangs headless.
    sudo -u "$CONSOLE_USER" env NONINTERACTIVE=1 bash "$install_script" 2>&1 | \
        tail -5 | while read -r line; do log_info "  brew-install: $line"; done
    local rc=${PIPESTATUS[0]}
    if [ $rc -eq 0 ] && [ -x "$BREW" ]; then
        log_ok "Homebrew installed."
    else
        log_warn "Homebrew install may have failed (exit $rc) — continuing."
    fi
}

install_git() {
    log_info "=== Git ==="
    if verify_cmd git; then log_ok "Git already installed — skipping."; return 0; fi

    # Git ships with the Xcode Command Line Tools. The interactive
    # 'xcode-select --install' GUI dialog never appears on a headless NinjaOne
    # run, so drive the install through softwareupdate instead.
    log_info "Installing Xcode Command Line Tools (includes Git) via softwareupdate..."
    # softwareupdate only lists the CLT label while this sentinel file exists.
    local clt_trigger="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    touch "$clt_trigger"
    local clt_label
    clt_label=$(softwareupdate -l 2>/dev/null \
        | grep -E '[Cc]ommand [Ll]ine [Tt]ools' \
        | grep -E '^\s*\*' \
        | sed -E 's/^[[:space:]]*\*( Label:)?[[:space:]]*//' \
        | tail -1)
    rm -f "$clt_trigger"

    if [ -n "$clt_label" ]; then
        log_info "Installing CLT package: $clt_label"
        invoke_with_timeout 900 softwareupdate -i "$clt_label" --verbose 2>&1 | \
            tail -5 | while read -r line; do log_info "  CLT: $line"; done
    else
        log_warn "No Command Line Tools label found via softwareupdate."
    fi

    if verify_cmd git; then
        log_ok "Git installed via Xcode CLT."
        manifest_record "Git" "installed" "clt"
        return 0
    fi

    log_warn "Xcode CLT did not provide git — falling back to brew."
    if brew_install git false; then
        log_ok "Git installed via brew."
        manifest_record "Git" "installed" "brew"
        return 0
    fi
    log_fail "Git install failed."
    manifest_record "Git" "failed" "none"
    return 1
}

install_vscode() {
    log_info "=== VS Code ==="
    if verify_app "/Applications/Visual Studio Code.app"; then
        log_ok "VS Code already installed — skipping."
        return 0
    fi

    # Tier 1: Bundled zip
    local bundle="$BUNDLED_DIR/ME_Visual_Studio_Code_mac.zip"
    if [ -f "$bundle" ]; then
        log_info "Installing VS Code from bundled zip..."
        unzip -q "$bundle" -d "$TEMP_DIR/vscode_extract"
        local app
        app=$(find "$TEMP_DIR/vscode_extract" -name 'Visual Studio Code.app' -maxdepth 2 | head -1)
        if [ -n "$app" ]; then
            cp -R "$app" /Applications/
            rm -rf "$TEMP_DIR/vscode_extract"
            log_ok "VS Code installed from bundle."
            manifest_record "VS Code" "installed" "bundled"
            return 0
        fi
        rm -rf "$TEMP_DIR/vscode_extract"
    fi

    # Tier 2: Direct download
    log_info "Downloading VS Code..."
    local zip_path="$TEMP_DIR/vscode_mac.zip"
    if curl -fsSL 'https://update.code.visualstudio.com/latest/darwin-universal/stable' \
        -o "$zip_path"; then
        unzip -q "$zip_path" -d "$TEMP_DIR/vscode_extract"
        local app
        app=$(find "$TEMP_DIR/vscode_extract" -name 'Visual Studio Code.app' -maxdepth 2 | head -1)
        if [ -n "$app" ]; then
            cp -R "$app" /Applications/
            rm -rf "$TEMP_DIR/vscode_extract" "$zip_path"
            log_ok "VS Code installed from direct download."
            manifest_record "VS Code" "installed" "direct"
            return 0
        fi
        rm -rf "$TEMP_DIR/vscode_extract" "$zip_path"
    fi

    # Tier 3: Brew cask
    log_info "Falling back to brew cask for VS Code..."
    if brew_install "visual-studio-code"; then
        log_ok "VS Code installed via brew cask."
        manifest_record "VS Code" "installed" "brew"
        return 0
    fi

    log_fail "VS Code install failed."
    manifest_record "VS Code" "failed" "none"
    return 1
}

install_powershell() {
    log_info "=== PowerShell 7 ==="
    if verify_cmd pwsh; then log_ok "PowerShell 7 already installed — skipping."; return 0; fi

    # Tier 1: Bundled .pkg (arch-specific — Package-Release ships both variants)
    local bundle_arch
    bundle_arch=$([ "$(uname -m)" = "arm64" ] && echo "arm64" || echo "amd64")
    local bundle="$BUNDLED_DIR/ME_PowerShell_7_${bundle_arch}_mac.pkg"
    if [ -f "$bundle" ]; then
        log_info "Installing PowerShell 7 from bundled PKG..."
        if install_pkg "$bundle"; then
            log_ok "PowerShell 7 installed from bundle."
            manifest_record "PowerShell 7" "installed" "bundled"
            return 0
        fi
        log_warn "Bundled PKG install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading PowerShell 7..."
    local ps7_version
    ps7_version=$(curl -fsSL 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' \
        -H 'User-Agent: claude-setup-automation' 2>/dev/null | \
        grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    local arch
    arch=$([ "$(uname -m)" = "arm64" ] && echo "osx-arm64" || echo "osx-x64")
    local pkg_url="https://github.com/PowerShell/PowerShell/releases/latest/download/powershell-${ps7_version:-7.4.6}-${arch}.pkg"
    local pkg_path="$TEMP_DIR/powershell.pkg"
    if curl -fsSL "$pkg_url" -o "$pkg_path" && install_pkg "$pkg_path"; then
        rm -f "$pkg_path"
        log_ok "PowerShell 7 installed from direct download."
        manifest_record "PowerShell 7" "installed" "direct"
        return 0
    fi
    rm -f "$pkg_path"

    # Tier 3: Brew cask
    if brew_install "powershell"; then
        log_ok "PowerShell 7 installed via brew cask."
        manifest_record "PowerShell 7" "installed" "brew"
        return 0
    fi

    log_fail "PowerShell 7 install failed."
    manifest_record "PowerShell 7" "failed" "none"
    return 1
}

install_python() {
    log_info "=== Python 3.12 ==="
    if verify_cmd python3 && python3 --version 2>&1 | grep -q '3\.12'; then
        log_ok "Python 3.12 already installed — skipping."; return 0
    fi

    # Tier 1: Bundled .pkg
    local bundle="$BUNDLED_DIR/ME_Python_3_12_mac.pkg"
    if [ -f "$bundle" ]; then
        log_info "Installing Python 3.12 from bundled PKG..."
        if install_pkg "$bundle"; then
            log_ok "Python 3.12 installed from bundle."
            manifest_record "Python 3.12" "installed" "bundled"
            return 0
        fi
        log_warn "Bundled PKG install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading Python 3.12..."
    local pkg_url='https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg'
    local pkg_path="$TEMP_DIR/python312.pkg"
    if curl -fsSL "$pkg_url" -o "$pkg_path" && install_pkg "$pkg_path"; then
        rm -f "$pkg_path"
        log_ok "Python 3.12 installed from direct download."
        manifest_record "Python 3.12" "installed" "direct"
        return 0
    fi
    rm -f "$pkg_path"

    # Tier 3: Brew
    if brew_install "python@3.12" false; then
        log_ok "Python 3.12 installed via brew."
        manifest_record "Python 3.12" "installed" "brew"
        return 0
    fi

    log_fail "Python 3.12 install failed."
    manifest_record "Python 3.12" "failed" "none"
    return 1
}

install_awscli() {
    log_info "=== AWS CLI v2 ==="
    if verify_cmd aws; then log_ok "AWS CLI already installed — skipping."; return 0; fi

    # Tier 1: Bundled .pkg
    local bundle="$BUNDLED_DIR/ME_AWS_CLI_v2_mac.pkg"
    if [ -f "$bundle" ]; then
        log_info "Installing AWS CLI from bundled PKG..."
        if install_pkg "$bundle"; then
            log_ok "AWS CLI installed from bundle."
            manifest_record "AWS CLI v2" "installed" "bundled"
            return 0
        fi
        log_warn "Bundled PKG install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading AWS CLI v2..."
    local arch
    arch=$([ "$(uname -m)" = "arm64" ] && echo "arm64" || echo "x86_64")
    local pkg_url="https://awscli.amazonaws.com/AWSCLIV2.pkg"
    local pkg_path="$TEMP_DIR/awscli.pkg"
    if curl -fsSL "$pkg_url" -o "$pkg_path" && install_pkg "$pkg_path"; then
        rm -f "$pkg_path"
        log_ok "AWS CLI installed from direct download."
        manifest_record "AWS CLI v2" "installed" "direct"
        return 0
    fi
    rm -f "$pkg_path"

    # Tier 3: Brew
    if brew_install "awscli" false; then
        log_ok "AWS CLI installed via brew."
        manifest_record "AWS CLI v2" "installed" "brew"
        return 0
    fi

    log_fail "AWS CLI install failed."
    manifest_record "AWS CLI v2" "failed" "none"
    return 1
}

install_github_cli() {
    log_info "=== GitHub CLI ==="
    if verify_cmd gh; then log_ok "GitHub CLI already installed — skipping."; return 0; fi

    # Tier 1: Bundled tar.gz (arch-specific — Package-Release ships both variants)
    local bundle_arch
    bundle_arch=$([ "$(uname -m)" = "arm64" ] && echo "arm64" || echo "amd64")
    local bundle="$BUNDLED_DIR/ME_GitHub_CLI_${bundle_arch}.tar.gz"
    if [ -f "$bundle" ]; then
        log_info "Installing GitHub CLI from bundled archive..."
        local extract_dir="$TEMP_DIR/gh_extract"
        mkdir -p "$extract_dir"
        tar -xzf "$bundle" -C "$extract_dir" --strip-components=1
        if [ -f "$extract_dir/bin/gh" ]; then
            cp "$extract_dir/bin/gh" /usr/local/bin/gh
            chmod +x /usr/local/bin/gh
            rm -rf "$extract_dir"
            log_ok "GitHub CLI installed from bundle."
            manifest_record "GitHub CLI" "installed" "bundled"
            return 0
        fi
        rm -rf "$extract_dir"
        log_warn "Bundled archive install failed."
    fi

    # Tier 2: Direct download (latest release)
    log_info "Downloading GitHub CLI..."
    local arch
    arch=$([ "$(uname -m)" = "arm64" ] && echo "macOS_arm64" || echo "macOS_amd64")
    local gh_version
    gh_version=$(curl -fsSL 'https://api.github.com/repos/cli/cli/releases/latest' \
        -H 'User-Agent: claude-setup-automation' 2>/dev/null | \
        grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    local tar_url="https://github.com/cli/cli/releases/latest/download/gh_${gh_version}_${arch}.tar.gz"
    local tar_path="$TEMP_DIR/gh.tar.gz"
    if curl -fsSL "$tar_url" -o "$tar_path"; then
        local extract_dir="$TEMP_DIR/gh_extract"
        mkdir -p "$extract_dir"
        tar -xzf "$tar_path" -C "$extract_dir" --strip-components=1
        if [ -f "$extract_dir/bin/gh" ]; then
            cp "$extract_dir/bin/gh" /usr/local/bin/gh
            chmod +x /usr/local/bin/gh
            rm -rf "$extract_dir" "$tar_path"
            log_ok "GitHub CLI installed from direct download."
            manifest_record "GitHub CLI" "installed" "direct"
            return 0
        fi
        rm -rf "$extract_dir" "$tar_path"
    fi

    # Tier 3: Brew
    if brew_install "gh" false; then
        log_ok "GitHub CLI installed via brew."
        manifest_record "GitHub CLI" "installed" "brew"
        return 0
    fi

    log_fail "GitHub CLI install failed."
    manifest_record "GitHub CLI" "failed" "none"
    return 1
}

install_terraform() {
    log_info "=== Terraform ==="
    if verify_cmd terraform; then log_ok "Terraform already installed — skipping."; return 0; fi

    local arch
    arch=$([ "$(uname -m)" = "arm64" ] && echo "arm64" || echo "amd64")

    # Tier 1: Bundled .zip (arch-specific — Package-Release ships both variants;
    # $arch is already arm64/amd64 from the detection above)
    local bundle="$BUNDLED_DIR/ME_Terraform_${arch}_mac.zip"
    if [ -f "$bundle" ]; then
        log_info "Installing Terraform from bundled zip..."
        unzip -q "$bundle" -d "$TEMP_DIR/tf_extract"
        if [ -f "$TEMP_DIR/tf_extract/terraform" ]; then
            cp "$TEMP_DIR/tf_extract/terraform" /usr/local/bin/terraform
            chmod +x /usr/local/bin/terraform
            rm -rf "$TEMP_DIR/tf_extract"
            log_ok "Terraform installed from bundle."
            manifest_record "Terraform" "installed" "bundled"
            return 0
        fi
        rm -rf "$TEMP_DIR/tf_extract"
        log_warn "Bundled zip install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading Terraform..."
    local tf_version
    tf_version=$(curl -fsSL 'https://checkpoint-api.hashicorp.com/v1/check/terraform' \
        2>/dev/null | grep -o '"current_version":"[^"]*"' | sed 's/.*"\([^"]*\)".*/\1/')
    tf_version="${tf_version:-1.9.0}"
    local zip_url="https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_darwin_${arch}.zip"
    local zip_path="$TEMP_DIR/terraform.zip"
    if curl -fsSL "$zip_url" -o "$zip_path"; then
        unzip -q "$zip_path" -d "$TEMP_DIR/tf_extract"
        if [ -f "$TEMP_DIR/tf_extract/terraform" ]; then
            cp "$TEMP_DIR/tf_extract/terraform" /usr/local/bin/terraform
            chmod +x /usr/local/bin/terraform
            rm -rf "$TEMP_DIR/tf_extract" "$zip_path"
            log_ok "Terraform installed from direct download."
            manifest_record "Terraform" "installed" "direct"
            return 0
        fi
        rm -rf "$TEMP_DIR/tf_extract" "$zip_path"
    fi

    # Tier 3: Brew
    if brew_install "terraform" false; then
        log_ok "Terraform installed via brew."
        manifest_record "Terraform" "installed" "brew"
        return 0
    fi

    log_fail "Terraform install failed."
    manifest_record "Terraform" "failed" "none"
    return 1
}

install_docker() {
    log_info "=== Docker Desktop ==="
    if verify_app "/Applications/Docker.app"; then
        log_ok "Docker Desktop already installed — skipping."; return 0
    fi

    # Tier 1: Bundled .dmg (optional — ~600 MB, may not be bundled)
    local bundle="$BUNDLED_DIR/ME_Docker_Desktop_mac.dmg"
    if [ -f "$bundle" ]; then
        log_info "Installing Docker Desktop from bundled DMG..."
        if install_dmg "$bundle" "Docker.app"; then
            log_ok "Docker Desktop installed from bundle."
            manifest_record "Docker Desktop" "installed" "bundled"
            return 0
        fi
        log_warn "Bundled DMG install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading Docker Desktop..."
    local arch
    arch=$([ "$(uname -m)" = "arm64" ] && echo "arm64" || echo "amd64")
    local dmg_url="https://desktop.docker.com/mac/main/${arch}/Docker.dmg"
    local dmg_path="$TEMP_DIR/Docker.dmg"
    if invoke_with_timeout 900 curl -fsSL "$dmg_url" -o "$dmg_path"; then
        if install_dmg "$dmg_path" "Docker.app"; then
            rm -f "$dmg_path"
            log_ok "Docker Desktop installed from direct download."
            manifest_record "Docker Desktop" "installed" "direct"
            return 0
        fi
        rm -f "$dmg_path"
    fi

    # Tier 3: Brew cask
    if invoke_with_timeout 900 brew_install "docker"; then
        log_ok "Docker Desktop installed via brew cask."
        manifest_record "Docker Desktop" "installed" "brew"
        return 0
    fi

    log_fail "Docker Desktop install failed."
    manifest_record "Docker Desktop" "failed" "none"
    return 1
}

install_nvm_and_node() {
    log_info "=== nvm + Node.js ==="

    # nvm installs per-user — install to a system-wide location accessible to all
    NVM_DIR="/Library/MasterElectronics/nvm"
    mkdir -p "$NVM_DIR"
    export NVM_DIR

    if [ -f "$NVM_DIR/nvm.sh" ]; then
        log_ok "nvm already installed — sourcing."
    else
        # Tier 1: Bundled nvm install script
        local bundle="$BUNDLED_DIR/ME_nvm_install.sh"
        if [ -f "$bundle" ]; then
            log_info "Installing nvm from bundled script..."
            if NVM_DIR="$NVM_DIR" bash "$bundle" 2>&1 | tail -3 | while read -r l; do log_info "  nvm: $l"; done; then
                log_ok "nvm installed from bundle."
                manifest_record "nvm" "installed" "bundled"
            else
                log_warn "Bundled nvm install failed."
            fi
        fi

        # Tier 2: Download nvm install script
        if [ ! -f "$NVM_DIR/nvm.sh" ]; then
            log_info "Downloading nvm install script..."
            local nvm_install="$TEMP_DIR/nvm-install.sh"
            if curl -fsSL 'https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh' -o "$nvm_install"; then
                if NVM_DIR="$NVM_DIR" bash "$nvm_install" 2>&1 | tail -3 | while read -r l; do log_info "  nvm: $l"; done; then
                    log_ok "nvm installed from direct download."
                    manifest_record "nvm" "installed" "direct"
                else
                    log_fail "nvm install failed."
                    manifest_record "nvm" "failed" "none"
                    return 1
                fi
            fi
        fi
    fi

    # Source nvm
    # shellcheck source=/dev/null
    [ -f "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh" || {
        log_fail "Could not source nvm.sh"
        return 1
    }

    # Node.js — Tier 1: Bundled .pkg
    local node_bundle="$BUNDLED_DIR/ME_Node_LTS_mac.pkg"
    if [ -f "$node_bundle" ]; then
        log_info "Installing Node.js from bundled PKG..."
        if install_pkg "$node_bundle"; then
            log_ok "Node.js installed from bundle."
            manifest_record "Node.js" "installed" "bundled"
            # Point nvm at the system Node so npm global works
            NODE_PATH=$(command -v node 2>/dev/null || echo "/usr/local/bin/node")
            return 0
        fi
        log_warn "Bundled Node PKG install failed — trying nvm install."
    fi

    # Node.js — Tier 2: nvm install LTS
    log_info "Installing Node.js LTS via nvm..."
    if nvm install --lts 2>&1 | tail -3 | while read -r l; do log_info "  nvm: $l"; done; then
        nvm use --lts
        nvm alias default 'lts/*'
        log_ok "Node.js $(node --version) installed via nvm."
        manifest_record "Node.js" "installed" "direct"
    else
        log_fail "Node.js install via nvm failed."
        manifest_record "Node.js" "failed" "none"
        return 1
    fi
}

install_claude_code() {
    log_info "=== Claude Code ==="
    # Claude Code is a native binary now — NOT an npm package. It does not require
    # Node/npm to install or run, and it trusts the macOS System keychain by default
    # (CLAUDE_CODE_CERT_STORE=bundled,system) so it works behind Zscaler without
    # NODE_EXTRA_CA_CERTS. Installed machine-wide to mirror the Windows model.

    local claude_bin="/usr/local/bin/claude"
    if command -v claude &>/dev/null || [ -x "$claude_bin" ]; then
        local cur; cur=$("$claude_bin" --version 2>/dev/null || claude --version 2>/dev/null || echo "installed")
        log_ok "Claude Code already installed: $cur"
        manifest_record "Claude Code" "installed" "native"
        return 0
    fi

    local base="https://downloads.claude.ai/claude-code-releases"
    local plat
    plat=$([ "$(uname -m)" = "arm64" ] && echo "darwin-arm64" || echo "darwin-x64")

    # ── Tier 1: Direct CDN download + SHA256 verify (machine-wide, no Node) ──────
    log_info "Installing Claude Code (native binary, $plat)..."
    local ver
    ver=$(curl -fsSL "$base/latest" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ver" ]; then
        log_info "  Latest version: $ver"
        local manifest expected
        manifest=$(curl -fsSL "$base/$ver/manifest.json" 2>/dev/null)
        expected=$(printf '%s' "$manifest" | \
            python3 -c "import sys,json;print(json.load(sys.stdin)['platforms']['$plat']['checksum'])" 2>/dev/null)
        # Fallback parse if python3 is unavailable (no jq dependency).
        if [ -z "$expected" ]; then
            expected=$(printf '%s' "$manifest" | grep -A2 "\"$plat\"" | grep -oE '[a-f0-9]{64}' | head -1)
        fi
        local tmp="$TEMP_DIR/claude-$ver-$plat"
        if invoke_with_timeout 120 curl -fsSL "$base/$ver/$plat/claude" -o "$tmp"; then
            local actual
            actual=$(shasum -a 256 "$tmp" 2>/dev/null | awk '{print $1}')
            if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
                log_warn "  Checksum mismatch (expected $expected, got $actual) — discarding."
                rm -f "$tmp"
            else
                [ -z "$expected" ] && log_warn "  No checksum found in manifest — installing unverified."
                chmod +x "$tmp"
                mv -f "$tmp" "$claude_bin"
                log_ok "Claude Code installed (native): $("$claude_bin" --version 2>/dev/null || echo "$ver")"
                manifest_record "Claude Code" "installed" "native"
                return 0
            fi
        else
            log_warn "  Native binary download failed."
        fi
    else
        log_warn "  Could not determine latest Claude Code version from CDN."
    fi

    # ── Tier 2: Official native install script (still no Node), as the console user ─
    log_info "  Falling back to official native install script..."
    local inst="$TEMP_DIR/claude-install.sh"
    if curl -fsSL 'https://claude.ai/install.sh' -o "$inst"; then
        sudo -u "$CONSOLE_USER" bash "$inst" 2>&1 | \
            tail -5 | while read -r l; do log_info "  claude-install: $l"; done
        # The script installs per-user to ~/.local/bin; expose it machine-wide via symlink.
        if [ -x "$CONSOLE_HOME/.local/bin/claude" ]; then
            ln -sf "$CONSOLE_HOME/.local/bin/claude" "$claude_bin" 2>/dev/null || true
            log_ok "Claude Code installed (native install script) for $CONSOLE_USER."
            log_warn "  Installed per-user under $CONSOLE_HOME/.local/bin — other users may need a re-run at logon."
            manifest_record "Claude Code" "installed" "native-script"
            return 0
        fi
    fi

    log_fail "Claude Code install failed (native binary + script both failed)."
    manifest_record "Claude Code" "failed" "none"
    return 1
}

install_claude_desktop() {
    log_info "=== Claude Desktop ==="
    if verify_app "/Applications/Claude.app"; then
        log_ok "Claude Desktop already installed — skipping."; return 0
    fi

    # Tier 1: Bundled .dmg
    local bundle="$BUNDLED_DIR/ME_Claude_Desktop_mac.dmg"
    if [ -f "$bundle" ]; then
        log_info "Installing Claude Desktop from bundled DMG..."
        if install_dmg "$bundle" "Claude.app"; then
            log_ok "Claude Desktop installed from bundle."
            manifest_record "Claude Desktop" "installed" "bundled"
            return 0
        fi
        log_warn "Bundled DMG install failed."
    fi

    # Tier 2: Direct download
    log_info "Downloading Claude Desktop..."
    local dmg_url='https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-apple/Claude.dmg'
    local dmg_path="$TEMP_DIR/Claude.dmg"
    if invoke_with_timeout 300 curl -fsSL "$dmg_url" -o "$dmg_path"; then
        if install_dmg "$dmg_path" "Claude.app"; then
            rm -f "$dmg_path"
            log_ok "Claude Desktop installed from direct download."
            manifest_record "Claude Desktop" "installed" "direct"
            return 0
        fi
        rm -f "$dmg_path"
    fi

    # Tier 3: Brew cask
    if brew_install "claude"; then
        log_ok "Claude Desktop installed via brew cask."
        manifest_record "Claude Desktop" "installed" "brew"
        return 0
    fi

    log_fail "Claude Desktop install failed."
    manifest_record "Claude Desktop" "failed" "none"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN — run all installs, then configure user profiles
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    log_info "======================================================"
    log_info "  Master Electronics Dev Environment — macOS Installer"
    log_info "  Host: $(hostname) | User: $CONSOLE_USER | Arch: $(uname -m)"
    log_info "======================================================"

    PASS=0; FAIL=0

    run_install() {
        local name="$1"; shift
        if "$@"; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            log_fail "$name install reported failure."
        fi
    }

    install_homebrew  # Required for brew-tier fallbacks — always run first

    run_install "Git"             install_git
    run_install "VS Code"         install_vscode
    run_install "PowerShell 7"    install_powershell
    run_install "Python 3.12"     install_python
    run_install "AWS CLI v2"      install_awscli
    run_install "GitHub CLI"      install_github_cli
    run_install "Terraform"       install_terraform
    run_install "Docker Desktop"  install_docker
    run_install "nvm + Node.js"   install_nvm_and_node
    run_install "Claude Code"     install_claude_code
    run_install "Claude Desktop"  install_claude_desktop

    # ── Verify report ──────────────────────────────────────────────────────────
    {
        echo "Install results: $PASS passed, $FAIL failed"
        echo "---"
        for tool_check in \
            "Git:git" \
            "VS Code:code" \
            "PowerShell 7:pwsh" \
            "Python 3.12:python3" \
            "AWS CLI v2:aws" \
            "GitHub CLI:gh" \
            "Terraform:terraform" \
            "Docker:docker" \
            "Node.js:node" \
            "npm:npm" \
            "Claude Code:claude"; do
            local label="${tool_check%%:*}"
            local cmd="${tool_check##*:}"
            if verify_cmd "$cmd"; then
                local ver
                ver=$("$cmd" --version 2>/dev/null | head -1 || echo "installed")
                echo "  [OK]   $label — $ver"
            else
                echo "  [FAIL] $label — not found on PATH"
            fi
        done
        # nvm is a shell function, not a binary — verify by file, not PATH.
        if [ -f "${NVM_DIR:-/Library/MasterElectronics/nvm}/nvm.sh" ]; then
            echo "  [OK]   nvm — installed at ${NVM_DIR:-/Library/MasterElectronics/nvm}"
        else
            echo "  [FAIL] nvm — nvm.sh missing"
        fi
        [ -d "/Applications/Visual Studio Code.app" ] && echo "  [OK]   VS Code.app present" || echo "  [FAIL] VS Code.app missing"
        [ -d "/Applications/Docker.app" ]             && echo "  [OK]   Docker.app present"   || echo "  [WARN] Docker.app missing"
        [ -d "/Applications/Claude.app" ]             && echo "  [OK]   Claude Desktop present" || echo "  [WARN] Claude.app missing"
    } | tee "$VERIFY_INSTALL"

    # ── Write manifest ─────────────────────────────────────────────────────────
    cat > "$MANIFEST" <<EOF
{
  "SchemaVersion": "1.1",
  "InstalledAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "Host": "$(hostname)",
  "OS": "$(sw_vers -productName) $(sw_vers -productVersion)",
  "Arch": "$(uname -m)",
  "Packages": $MANIFEST_ENTRIES
}
EOF

    # ── Configure user profiles ────────────────────────────────────────────────
    local config_script="$SCRIPT_DIR/Configure-UserEnvironment.sh"
    if [ -f "$config_script" ]; then
        log_info "Configuring user profile for $CONSOLE_USER..."
        chmod +x "$config_script"
        sudo -u "$CONSOLE_USER" bash "$config_script" "$CONSOLE_USER" 2>&1 | \
            tee -a "$INSTALL_LOG"
    fi

    # ── Completion notification ────────────────────────────────────────────────
    sudo -u "$CONSOLE_USER" osascript -e \
        'display notification "Developer tools installation complete. Please restart your Mac to finalize setup." with title "Master Electronics IT"' \
        2>/dev/null || true

    log_info "======================================================"
    log_info "  Install complete: $PASS passed, $FAIL failed"
    log_info "  Log: $INSTALL_LOG"
    log_info "  Manifest: $MANIFEST"
    log_info "======================================================"

    [ $FAIL -eq 0 ] && exit 0 || exit 1
}

main "$@"
