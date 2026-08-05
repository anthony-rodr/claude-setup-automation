#!/bin/bash
# Tier 2 — Deploy script (downloaded fresh from S3 via the Lambda-presigned URL on
# every run). Runs as root. Checks VERSIONS.md staleness, downloads the release zip,
# verifies its integrity, extracts it, then hands off to Install-DevEnvironment.sh.
#
# PACKAGE_URL / VERSIONS_URL are passed in as environment variables by
# ninjaone/NinjaOne-Bootstrap.sh (pre-signed S3 URLs resolved via Lambda) - this
# script must never hardcode a download source itself.
#
# NinjaOne bootstrap always pulls the latest version of THIS file from S3 - no
# NinjaOne update needed unless the bootstrap script itself changes.

set -uo pipefail

SCRIPT_VERSION='7d249f7'  # Stamped by Package-Release.sh

if [ -z "${PACKAGE_URL:-}" ]; then
    echo "[ERROR] PACKAGE_URL environment variable is required (set by NinjaOne-Bootstrap.sh)." >&2
    exit 1
fi
if [ -z "${VERSIONS_URL:-}" ]; then
    echo "[ERROR] VERSIONS_URL environment variable is required (set by NinjaOne-Bootstrap.sh)." >&2
    exit 1
fi

STAGE_DIR='/Library/AIE/Deploy'
ZIP_PATH="$STAGE_DIR/setup.zip"
EXTRACT_DIR="$STAGE_DIR/package"
VERSIONS_ON_DISK="$STAGE_DIR/VERSIONS.md"

step() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Banner ─────────────────────────────────────────────────────────────────────
echo "$(printf '=%.0s' {1..64})"
echo "  AIE — Developer Environment DEPLOY (macOS)"
echo "$(printf '=%.0s' {1..64})"
echo "  Script version: $SCRIPT_VERSION"
echo "$(printf '=%.0s' {1..64})"

mkdir -p "$STAGE_DIR"

# ── Detect console user (brew must run as non-root) ───────────────────────────
CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo "")
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    # No interactive user — pick the first non-root admin account
    CONSOLE_USER=$(dscl . -list /Users UniqueID 2>/dev/null | \
        awk '$2 >= 500 && $2 < 60000 {print $1}' | \
        grep -v '^_' | head -1)
fi
if [ -z "$CONSOLE_USER" ]; then
    echo "[ERROR] Could not determine a non-root user to run Homebrew as. Aborting."
    exit 1
fi
step "Console/target user: $CONSOLE_USER"
export CONSOLE_USER

# ── Notify signed-on user ─────────────────────────────────────────────────────
step "Notifying user..."
sudo -u "$CONSOLE_USER" osascript -e \
    'display notification "IT Update: Developer tools are being deployed to this machine. Please save your work — a restart may be required when complete." with title "Master Electronics IT"' \
    2>/dev/null || step "  Could not send notification (no active session)."

# ── VERSIONS.md staleness check + ZipSHA256 extraction ────────────────────────
# Always fetched (even on first run) so the expected zip hash is available before
# downloading - mirrors scripts/Deploy-DevEnvironment.ps1's Windows equivalent.
SKIP_DOWNLOAD=false
EXPECTED_ZIP_HASH=""
REMOTE_VERSIONS=$(curl -fsSL -H 'User-Agent: aie-dev-setup' "$VERSIONS_URL" 2>/dev/null || echo "")
if [ -n "$REMOTE_VERSIONS" ]; then
    EXPECTED_ZIP_HASH=$(echo "$REMOTE_VERSIONS" | grep -E '^ZipSHA256:' | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    if [ -d "$EXTRACT_DIR" ] && [ -f "$VERSIONS_ON_DISK" ]; then
        step "Checking bundle version..."
        LOCAL_VERSIONS=$(cat "$VERSIONS_ON_DISK")
        INSTALL_PRESENT=$(find "$EXTRACT_DIR" -name 'Install-DevEnvironment.sh' 2>/dev/null | head -1)
        if [ -n "$INSTALL_PRESENT" ] && [ "$REMOTE_VERSIONS" = "$LOCAL_VERSIONS" ]; then
            step "Bundle is current (VERSIONS.md matches) — skipping download."
            SKIP_DOWNLOAD=true
        else
            step "New version detected or extracted package incomplete — re-downloading bundle."
        fi
    fi
fi

# ── Download, verify, and extract ──────────────────────────────────────────────
if [ "$SKIP_DOWNLOAD" = false ]; then
    [ -d "$EXTRACT_DIR" ] && rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    step "Downloading package..."
    if ! curl -fsSL \
        -H 'User-Agent: aie-dev-setup' \
        "$PACKAGE_URL" \
        -o "$ZIP_PATH"; then
        echo "[ERROR] Failed to download package."
        exit 1
    fi
    step "Download complete."

    if [ -n "$EXPECTED_ZIP_HASH" ]; then
        step "Verifying zip integrity..."
        if command -v shasum &>/dev/null; then
            ACTUAL_ZIP_HASH=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
        else
            ACTUAL_ZIP_HASH=$(sha256sum "$ZIP_PATH" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
        fi
        if [ "$ACTUAL_ZIP_HASH" != "$EXPECTED_ZIP_HASH" ]; then
            rm -f "$ZIP_PATH"
            echo "[ERROR] ZIP integrity check FAILED — expected $EXPECTED_ZIP_HASH, got $ACTUAL_ZIP_HASH — aborting to prevent tampered package execution." >&2
            exit 1
        fi
        step "ZIP integrity verified."
    else
        step "WARNING: No ZipSHA256 found in VERSIONS.md — skipping integrity check."
    fi

    step "Extracting..."
    unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"
    step "Extraction complete."

    BUNDLED_VERSIONS=$(find "$EXTRACT_DIR" -name 'VERSIONS.md' 2>/dev/null | head -1)
    [ -n "$BUNDLED_VERSIONS" ] && cp "$BUNDLED_VERSIONS" "$VERSIONS_ON_DISK"
    rm -f "$ZIP_PATH"
fi

# ── Locate install script ──────────────────────────────────────────────────────
INSTALL_SCRIPT=$(find "$EXTRACT_DIR" -name 'Install-DevEnvironment.sh' 2>/dev/null | head -1)
if [ -z "$INSTALL_SCRIPT" ]; then
    echo "[ERROR] Install-DevEnvironment.sh not found in extracted package."
    exit 1
fi
PKG_ROOT=$(dirname "$(dirname "$INSTALL_SCRIPT")")
step "Found install script: $INSTALL_SCRIPT"

# ── Integrity check ───────────────────────────────────────────────────────────
REQUIRED=(
    "scripts/Install-DevEnvironment.sh"
    "scripts/Configure-UserEnvironment.sh"
    "bundled/ME_nvm_install.sh"
    "bundled/ME_Node_LTS_mac.pkg"
)
for REL in "${REQUIRED[@]}"; do
    if [ ! -f "$PKG_ROOT/$REL" ]; then
        echo "[ERROR] Required package file missing after extraction: $REL"
        exit 1
    fi
done
step "Package integrity check passed."

# ── Run installer ─────────────────────────────────────────────────────────────
step "Starting installation..."
chmod +x "$INSTALL_SCRIPT"
bash "$INSTALL_SCRIPT"
EXIT_CODE=$?
step "Installation completed with exit code: $EXIT_CODE"
exit $EXIT_CODE
