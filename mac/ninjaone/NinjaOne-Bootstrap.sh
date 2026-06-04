#!/bin/bash
# Tier 1 — NinjaOne Bootstrap (stored in NinjaOne, NOT in the repo zip)
# Runs as root via NinjaOne agent. Downloads Deploy-DevEnvironment.sh fresh
# from GitHub on every run, then hands off to it.
#
# To update bootstrap logic: edit this file and re-paste into NinjaOne.
# To update the installer: push to GitHub — Deploy pulls latest automatically.

set -uo pipefail

ROOT="/Library/MasterElectronics"
LOG_DIR="$ROOT/Logs"
mkdir -p "$LOG_DIR"

STAMP=$(date '+%Y%m%d-%H%M%S')
NINJA_LOG="$LOG_DIR/ninja-deploy-$STAMP.log"
DEPLOY_SCRIPT="$LOG_DIR/Deploy-DevEnvironment.sh"
DEPLOY_OUT="$LOG_DIR/deploy-output-$STAMP.log"
DEPLOY_ERR="$LOG_DIR/deploy-error-$STAMP.log"

LOCKFILE="/var/run/me-devsetup.lock"

ninja_log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line" | tee -a "$NINJA_LOG"
}

# ── Mutex via lock file ────────────────────────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        ninja_log "Another Master Electronics Dev Environment install is already running (PID $LOCK_PID). Exiting."
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

ninja_log "Bootstrap started. Host: $(hostname)"
ninja_log "Running as: $(id -un) ($(id))"

# ── Download deploy script ─────────────────────────────────────────────────────
DEPLOY_URL='https://raw.githubusercontent.com/anthony-rodr/claude-setup-automation/main/mac/scripts/Deploy-DevEnvironment.sh'
ninja_log "Downloading deploy script from GitHub..."

if ! curl -fsSL \
    -H 'User-Agent: claude-setup-automation' \
    "$DEPLOY_URL" \
    -o "$DEPLOY_SCRIPT"; then
    ninja_log "ERROR: Failed to download deploy script."
    exit 1
fi
chmod +x "$DEPLOY_SCRIPT"
ninja_log "Deploy script downloaded. Starting installer..."

# ── Run deploy script with 90-minute timeout ───────────────────────────────────
START_TIME=$(date +%s)
FINAL_EXIT=1

if timeout 5400 bash "$DEPLOY_SCRIPT" \
    >"$DEPLOY_OUT" 2>"$DEPLOY_ERR"; then
    FINAL_EXIT=0
else
    FINAL_EXIT=$?
    if [ $FINAL_EXIT -eq 124 ]; then
        ninja_log "Deploy timed out after 90 minutes."
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
ninja_log "Install finished in $((DURATION/60))m $((DURATION%60))s. Exit code: $FINAL_EXIT"

# ── Summary output (mirrors Windows bootstrap) ─────────────────────────────────
VERIFY_INSTALL="$ROOT/verify-install.log"
VERIFY_CONFIGURE="$ROOT/verify-configure.log"
INSTALL_LOG="$ROOT/DevSetup/install.log"

echo ""
echo "========== TOOL INSTALLATION =========="
if [ -f "$VERIFY_INSTALL" ]; then cat "$VERIFY_INSTALL"; else echo "verify-install.log not found at $VERIFY_INSTALL"; fi

echo ""
echo "========== USER PROFILE CONFIG =========="
if [ -f "$VERIFY_CONFIGURE" ]; then cat "$VERIFY_CONFIGURE"; else echo "verify-configure.log not found at $VERIFY_CONFIGURE"; fi

echo ""
echo "========== WARNINGS / FAILURES =========="
if [ -f "$INSTALL_LOG" ]; then
    WARN_LINES=$(grep -E '^\[.*\]\[(WARN|FAIL)\]' "$INSTALL_LOG" 2>/dev/null | tail -30)
    if [ -n "$WARN_LINES" ]; then echo "$WARN_LINES"; else echo "None."; fi
else
    echo "install.log not found at $INSTALL_LOG"
fi

if [ -s "$DEPLOY_ERR" ]; then
    echo ""
    echo "========== STDERR TAIL ================"
    tail -20 "$DEPLOY_ERR"
    echo "======================================="
fi
echo "========================================="

ninja_log "Full install log   : $INSTALL_LOG"
ninja_log "Full deploy output : $DEPLOY_OUT"
ninja_log "Full deploy errors : $DEPLOY_ERR"
ninja_log "Bootstrap exiting with code $FINAL_EXIT"

exit $FINAL_EXIT
