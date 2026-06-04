#!/bin/bash
# Runs per-user to configure shell profile, PATH, VS Code extensions, and shortcuts.
# Called by Install-DevEnvironment.sh as the console user (not root).
# Can also be attached to a launchd LoginHook to re-run at each login.
#
# Usage: bash Configure-UserEnvironment.sh [username]

set -uo pipefail

TARGET_USER="${1:-$(id -un)}"
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
TARGET_HOME="${TARGET_HOME:-/Users/$TARGET_USER}"

ROOT="/Library/MasterElectronics"
VERIFY_CONFIGURE="$ROOT/verify-configure.log"
MARKER="$TARGET_HOME/.claude/.devsetup-configured"
NVM_DIR="/Library/MasterElectronics/nvm"
NPM_GLOBAL="/Library/MasterElectronics/npm"

BREW_PREFIX=$([ "$(uname -m)" = "arm64" ] && echo "/opt/homebrew" || echo "/usr/local")

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Skip if already configured ────────────────────────────────────────────────
if [ -f "$MARKER" ]; then
    log "Profile already configured for $TARGET_USER — skipping."
    exit 0
fi

log "Configuring environment for $TARGET_USER..."

# ── Shell profile — add to both .zshrc and .bash_profile ─────────────────────
configure_shell_profile() {
    local shell_config
    # macOS default shell is zsh since Catalina
    if [ -f "$TARGET_HOME/.zshrc" ] || [ "$SHELL" = "/bin/zsh" ]; then
        shell_config="$TARGET_HOME/.zshrc"
    else
        shell_config="$TARGET_HOME/.bash_profile"
    fi
    touch "$shell_config"

    local block_marker="# === Master Electronics Dev Setup ==="
    if grep -q "$block_marker" "$shell_config" 2>/dev/null; then
        log "Shell profile block already present in $shell_config — skipping."
        return 0
    fi

    cat >> "$shell_config" <<EOF

$block_marker
# nvm (system-wide install)
export NVM_DIR="$NVM_DIR"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
# bash_completion is bash-only; sourcing it under zsh errors, so guard on bash.
[ -n "\$BASH_VERSION" ] && [ -s "\$NVM_DIR/bash_completion" ] && source "\$NVM_DIR/bash_completion"

# npm global (system-wide)
export PATH="$NPM_GLOBAL/bin:\$PATH"

# Homebrew
eval "\$($BREW_PREFIX/bin/brew shellenv)" 2>/dev/null || true

# Terraform
export PATH="\$PATH:/usr/local/bin"
# === End Master Electronics Dev Setup ===
EOF
    log "Shell profile updated: $shell_config"
}

# ── VS Code extensions ────────────────────────────────────────────────────────
install_vscode_extensions() {
    local code_bin
    code_bin=$(command -v code 2>/dev/null || \
        ls "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" 2>/dev/null || \
        echo "")
    if [ -z "$code_bin" ]; then
        log "VS Code CLI not found — skipping extension install."
        return 0
    fi

    local extensions=(
        "ms-python.python"
        "ms-python.vscode-pylance"
        "ms-vscode.powershell"
        "ms-vscode-remote.remote-ssh"
        "hashicorp.terraform"
        "github.vscode-github-actions"
        "amazonwebservices.aws-toolkit-vscode"
        "eamodio.gitlens"
    )
    for ext in "${extensions[@]}"; do
        if "$code_bin" --list-extensions 2>/dev/null | grep -qi "^${ext}$"; then
            log "  VS Code extension already installed: $ext"
        else
            log "  Installing VS Code extension: $ext"
            "$code_bin" --install-extension "$ext" --force 2>/dev/null || \
                log "  Warning: could not install $ext"
        fi
    done
}

# ── Claude settings ───────────────────────────────────────────────────────────
configure_claude_settings() {
    local claude_dir="$TARGET_HOME/.claude"
    mkdir -p "$claude_dir"
    local settings_file="$claude_dir/settings.json"
    if [ ! -f "$settings_file" ]; then
        cat > "$settings_file" <<'EOF'
{
  "preferredShell": "/bin/zsh"
}
EOF
        log "Claude settings written: $settings_file"
    else
        log "Claude settings already present — skipping."
    fi
}

# ── PATH verification ─────────────────────────────────────────────────────────
verify_paths() {
    local report=""
    for tool_check in \
        "git:git" \
        "code:code" \
        "python3:python3" \
        "aws:aws" \
        "gh:gh" \
        "terraform:terraform" \
        "docker:docker" \
        "node:node" \
        "npm:npm" \
        "claude:claude"; do
        local label="${tool_check%%:*}"
        local cmd="${tool_check##*:}"
        if command -v "$cmd" &>/dev/null || \
           [ -x "$NPM_GLOBAL/bin/$cmd" ] || \
           [ -x "$BREW_PREFIX/bin/$cmd" ]; then
            local ver
            ver=$(command -v "$cmd" &>/dev/null && "$cmd" --version 2>/dev/null | head -1 || echo "installed")
            report+="  [OK]   $label — $ver\n"
        else
            report+="  [WARN] $label — not on PATH for $TARGET_USER\n"
        fi
    done
    # Check apps
    [ -d "/Applications/Visual Studio Code.app" ] && \
        report+="  [OK]   VS Code.app present\n" || \
        report+="  [WARN] VS Code.app missing\n"
    [ -d "/Applications/Claude.app" ] && \
        report+="  [OK]   Claude Desktop present\n" || \
        report+="  [WARN] Claude.app missing\n"
    printf "%b" "$report"
}

# ── Run all configuration steps ───────────────────────────────────────────────
configure_shell_profile
configure_claude_settings
install_vscode_extensions

{
    echo "User profile config for: $TARGET_USER"
    echo "Configured at: $(date)"
    echo "---"
    verify_paths
} | tee "$VERIFY_CONFIGURE"

# ── Write marker so logon task skips on subsequent logins ────────────────────
mkdir -p "$TARGET_HOME/.claude"
touch "$MARKER"
log "Marker written: $MARKER"
log "User profile configuration complete for $TARGET_USER."
