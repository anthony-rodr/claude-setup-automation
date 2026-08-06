#!/bin/bash
# AIE Dev Environment — NinjaOne Bootstrap (macOS)
# Stored inline in NinjaOne, NOT in the repo zip.
# Calls Lambda for pre-signed S3 URLs — lambdakey Script Variable must be configured in NinjaOne.
#
# To update bootstrap logic: edit this file and re-paste into NinjaOne.
# To push a new installer: run the PSU Build-And-Upload-Mac job — no NinjaOne update needed.

set -uo pipefail

# Lambda URL is permanent — never needs updating in NinjaOne.
LAMBDA_URL='https://dqjiychkx3ockgvn24rscxkmaq0wwfat.lambda-url.us-east-2.on.aws/'

# NinjaOne passes Script Variables as environment variables.
API_KEY="${lambdakey:-}"
if [ -z "$API_KEY" ]; then
    echo "[ERROR] lambdakey script variable is not configured in NinjaOne." >&2
    exit 1
fi

ROOT="/Library/AIE"
LOG_DIR="$ROOT/Logs"
mkdir -p "$LOG_DIR"

STAMP=$(date '+%Y%m%d-%H%M%S')
NINJA_LOG="$LOG_DIR/ninja-deploy-$STAMP.log"
DEPLOY_SCRIPT="$LOG_DIR/Deploy-DevEnvironment.sh"
DEPLOY_OUT="$LOG_DIR/deploy-output-$STAMP.log"
DEPLOY_ERR="$LOG_DIR/deploy-error-$STAMP.log"

LOCKFILE="/var/run/aie-devsetup.lock"

ninja_log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line" | tee -a "$NINJA_LOG"
}

get_lambda_url() {
    local file="$1"
    local response
    response=$(curl -fsSL --connect-timeout 15 --max-time 30 \
        -H "x-api-key: ${API_KEY}" \
        -H 'User-Agent: aie-dev-setup' \
        "${LAMBDA_URL}?file=${file}" 2>&1) || {
        # curl's own error (timeout, TLS failure, HTTP 4xx/5xx) is already in
        # $response via 2>&1 - previously discarded here, leaving only a
        # generic message with no way to tell timeout vs auth vs TLS apart.
        echo "[ERROR] Lambda call failed for file=$file: $response" >&2
        return 1
    }
    local url
    url=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])" 2>/dev/null || true)
    # Fallback parse if python3 is unavailable (no jq dependency) - same pattern used
    # elsewhere in this pipeline (Install-DevEnvironment.sh's Claude Code checksum parse).
    # Confirmed needed in practice: a stock Mac with no Xcode Command Line Tools has no
    # usable python3 in a non-interactive root session (2026-08-04 real deploy failure -
    # Lambda returned a perfectly valid {"url": "..."} response, but the python3 parse
    # silently produced nothing).
    if [ -z "$url" ]; then
        url=$(echo "$response" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    if [ -z "$url" ]; then
        echo "[ERROR] Lambda returned no URL for file=$file (response: $response)" >&2
        return 1
    fi
    echo "$url"
}

# ── Mutex via lock file ────────────────────────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        ninja_log "Another AIE Dev Environment install is already running (PID $LOCK_PID). Exiting."
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

ninja_log "Bootstrap started. Host: $(hostname)"
ninja_log "Running as: $(id -un) ($(id))"

# ── Resolve pre-signed URLs via Lambda ────────────────────────────────────────
ninja_log "Resolving download URLs via Lambda..."
VERSIONS_URL=$(get_lambda_url 'mac-versions') || { ninja_log "ERROR: Failed to get mac-versions URL."; exit 1; }
DEPLOY_URL=$(get_lambda_url 'mac-deploy')     || { ninja_log "ERROR: Failed to get mac-deploy URL."; exit 1; }
PACKAGE_URL=$(get_lambda_url 'mac-package')   || { ninja_log "ERROR: Failed to get mac-package URL."; exit 1; }
ninja_log "URLs resolved."

# ── Fetch VERSIONS.md and extract expected Deploy SHA256 ───────────────────────
ninja_log "Fetching VERSIONS.md for integrity check..."
VERSIONS_CONTENT=$(curl -fsSL -H 'User-Agent: aie-dev-setup' "$VERSIONS_URL" 2>/dev/null) || {
    ninja_log "ERROR: Failed to download VERSIONS.md."
    exit 1
}
EXPECTED_DEPLOY_HASH=$(echo "$VERSIONS_CONTENT" | grep -E '^DeploySHA256:' | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
if [ -z "$EXPECTED_DEPLOY_HASH" ]; then
    ninja_log "ERROR: DeploySHA256 not found in VERSIONS.md. Re-run PSU Build-And-Upload-Mac and re-upload all S3 files."
    exit 1
fi

# ── Download and verify Deploy script ─────────────────────────────────────────
ninja_log "Downloading deploy script..."
if ! curl -fsSL -H 'User-Agent: aie-dev-setup' "$DEPLOY_URL" -o "$DEPLOY_SCRIPT"; then
    ninja_log "ERROR: Failed to download deploy script."
    exit 1
fi

# shasum is built into macOS; sha256sum is GNU (Linux). Try both.
if command -v shasum &>/dev/null; then
    ACTUAL_DEPLOY_HASH=$(shasum -a 256 "$DEPLOY_SCRIPT" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
else
    ACTUAL_DEPLOY_HASH=$(sha256sum "$DEPLOY_SCRIPT" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
fi

if [ "$ACTUAL_DEPLOY_HASH" != "$EXPECTED_DEPLOY_HASH" ]; then
    ninja_log "ERROR: Deploy script integrity check FAILED."
    ninja_log "  Expected: $EXPECTED_DEPLOY_HASH"
    ninja_log "  Actual  : $ACTUAL_DEPLOY_HASH"
    exit 1
fi
ninja_log "Deploy script verified (SHA256 OK). Starting installer..."
chmod +x "$DEPLOY_SCRIPT"

# macOS's BSD userland does not ship GNU coreutils' `timeout` (Linux/Homebrew-coreutils
# only) - confirmed via a real deploy failure on a stock Mac exiting 127 "timeout:
# command not found" (2026-08-04). Portable replacement: background the deploy, race a
# watcher that kills it after the timeout, and translate "we killed it" to exit 124 so
# the existing `-eq 124` check below still works unchanged.
run_deploy_with_timeout() {
    local timeout_secs="$1"; shift
    local sentinel
    sentinel=$(mktemp)
    rm -f "$sentinel"

    "$@" &
    local child_pid=$!

    (
        sleep "$timeout_secs"
        if kill -0 "$child_pid" 2>/dev/null; then
            touch "$sentinel"
            kill -TERM "$child_pid" 2>/dev/null
        fi
    ) &
    local watcher_pid=$!

    wait "$child_pid" 2>/dev/null
    local exit_code=$?

    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null

    if [ -f "$sentinel" ]; then
        rm -f "$sentinel"
        return 124
    fi
    return $exit_code
}

# ── Run deploy script (90-minute timeout) ─────────────────────────────────────
# Pass pre-signed URLs via environment — Deploy uses them for staleness check and download.
START_TIME=$(date +%s)
FINAL_EXIT=1

if PACKAGE_URL="$PACKAGE_URL" VERSIONS_URL="$VERSIONS_URL" \
   run_deploy_with_timeout 5400 bash "$DEPLOY_SCRIPT" \
    >"$DEPLOY_OUT" 2>"$DEPLOY_ERR"; then
    FINAL_EXIT=0
else
    FINAL_EXIT=$?
    [ $FINAL_EXIT -eq 124 ] && ninja_log "Deploy timed out after 90 minutes."
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
ninja_log "Install finished in $((DURATION/60))m $((DURATION%60))s. Exit code: $FINAL_EXIT"

# ── Summary output ─────────────────────────────────────────────────────────────
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
