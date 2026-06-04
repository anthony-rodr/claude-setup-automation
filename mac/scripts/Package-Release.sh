#!/bin/bash
# Build script — run on dev machine to create mac-setup-automation.zip.
# Downloads bundled installers into bundled/, validates them, creates the zip,
# and generates mac-VERSIONS.md for the staleness check.
#
# Usage: bash scripts/Package-Release.sh
# Run from the repo root: cd /path/to/claude-setup-automation && bash mac/scripts/Package-Release.sh
#
# Re-runs are fast: already-present files in mac/bundled/ are skipped.
# Delete a file to force a refresh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLED_DIR="$MAC_DIR/bundled"
ZIP_NAME="mac-setup-automation.zip"
VERSIONS_FILE="$MAC_DIR/mac-VERSIONS.md"

GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

info()  { echo "[INFO] $*"; }
ok()    { echo "[ OK ] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ── Cross-platform helpers ────────────────────────────────────────────────────
# sed -i '' is macOS BSD sed; GNU sed (Git Bash on Windows) uses sed -i with no arg.
if sed --version 2>/dev/null | grep -q GNU; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# zip may not be present in Git Bash (Git for Windows). Fall back to python3 zipfile.
make_zip() {
    local zipfile="$1"; shift   # remaining args: paths to include
    if command -v zip &>/dev/null; then
        zip -r "$zipfile" "$@" \
            --exclude "*.DS_Store" \
            --exclude "*__MACOSX*" \
            --exclude "*/\.*"
    else
        info "zip not found — using python3 zipfile module."
        python3 - "$zipfile" "$@" <<'PYEOF'
import sys, zipfile, os, pathlib
outfile = sys.argv[1]
roots   = sys.argv[2:]
EXCLUDE = {'.DS_Store', '__MACOSX'}
with zipfile.ZipFile(outfile, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root in roots:
        for path in pathlib.Path(root).rglob('*'):
            if any(p in EXCLUDE for p in path.parts) or any(p.startswith('.') for p in path.parts):
                continue
            if path.is_file():
                zf.write(path)
PYEOF
    fi
}

mkdir -p "$BUNDLED_DIR"
cd "$MAC_DIR"

# ── Download helpers ──────────────────────────────────────────────────────────
download_if_missing() {
    local filename="$1" url="$2" description="$3"
    local dest="$BUNDLED_DIR/$filename"
    if [ -f "$dest" ]; then
        ok "$filename already present — skipping download."
        return 0
    fi
    info "Downloading $description..."
    if curl -fSL --progress-bar -H 'User-Agent: claude-setup-automation' \
        "$url" -o "$dest"; then
        ok "$filename downloaded ($(du -sh "$dest" | awk '{print $1}'))"
    else
        warn "Failed to download $description — $filename will be missing."
        return 1
    fi
}

get_gh_release_url() {
    local repo="$1" asset_pattern="$2"
    # grep may return exit 1 (no match) — treat as empty, not fatal.
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        -H 'User-Agent: claude-setup-automation' 2>/dev/null | \
        grep '"browser_download_url"' | grep "$asset_pattern" | \
        sed 's/.*"\(https[^"]*\)".*/\1/' | head -1 || true
}

# ── Bundled installers ────────────────────────────────────────────────────────
info "=== Downloading bundled installers ==="

# VS Code — universal build (Intel + Apple Silicon)
download_if_missing \
    "ME_Visual_Studio_Code_mac.zip" \
    "https://update.code.visualstudio.com/latest/darwin-universal/stable" \
    "VS Code (Mac Universal)"

# AWS CLI v2
download_if_missing \
    "ME_AWS_CLI_v2_mac.pkg" \
    "https://awscli.amazonaws.com/AWSCLIV2.pkg" \
    "AWS CLI v2"

# Python 3.12 (macOS 11+ universal2)
download_if_missing \
    "ME_Python_3_12_mac.pkg" \
    "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg" \
    "Python 3.12"

# GitHub CLI — arm64 and amd64 (both included; installer picks correct one)
GH_ARM_URL=$(get_gh_release_url "cli/cli" "macOS_arm64.tar.gz" || true)
GH_AMD_URL=$(get_gh_release_url "cli/cli" "macOS_amd64.tar.gz" || true)
[ -n "$GH_ARM_URL" ] && download_if_missing "ME_GitHub_CLI_arm64.tar.gz" "$GH_ARM_URL" "GitHub CLI (arm64)" \
    || warn "GitHub CLI arm64 URL unavailable — skipping (use cached file if present)."
[ -n "$GH_AMD_URL" ] && download_if_missing "ME_GitHub_CLI_amd64.tar.gz" "$GH_AMD_URL" "GitHub CLI (amd64)" \
    || warn "GitHub CLI amd64 URL unavailable — skipping (use cached file if present)."

# Terraform — arm64 and amd64
TF_VERSION=$(curl -fsSL 'https://checkpoint-api.hashicorp.com/v1/check/terraform' \
    2>/dev/null | grep -o '"current_version":"[^"]*"' | sed 's/.*"\([^"]*\)".*/\1/' || echo "1.9.0")
download_if_missing \
    "ME_Terraform_arm64_mac.zip" \
    "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_darwin_arm64.zip" \
    "Terraform $TF_VERSION (arm64)"
download_if_missing \
    "ME_Terraform_amd64_mac.zip" \
    "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_darwin_amd64.zip" \
    "Terraform $TF_VERSION (amd64)"

# PowerShell 7
PS7_URL=$(get_gh_release_url "PowerShell/PowerShell" "osx-arm64.pkg" || true)
PS7_AMD_URL=$(get_gh_release_url "PowerShell/PowerShell" "osx-x64.pkg" || true)
[ -n "$PS7_URL" ]     && download_if_missing "ME_PowerShell_7_arm64_mac.pkg" "$PS7_URL"     "PowerShell 7 (arm64)" \
    || warn "PowerShell 7 arm64 URL unavailable — skipping (use cached file if present)."
[ -n "$PS7_AMD_URL" ] && download_if_missing "ME_PowerShell_7_amd64_mac.pkg" "$PS7_AMD_URL" "PowerShell 7 (amd64)" \
    || warn "PowerShell 7 amd64 URL unavailable — skipping (use cached file if present)."

# nvm install script (pinned version)
NVM_VERSION="0.40.1"
download_if_missing \
    "ME_nvm_install.sh" \
    "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" \
    "nvm v${NVM_VERSION} install script"

# Node.js LTS — .pkg (system-wide install)
NODE_LTS_VERSION=$(curl -fsSL 'https://nodejs.org/dist/index.json' 2>/dev/null | \
    python3 -c "import sys,json; releases=[r for r in json.load(sys.stdin) if r.get('lts')]; print(releases[0]['version'])" \
    2>/dev/null || echo "v22.0.0")
download_if_missing \
    "ME_Node_LTS_mac.pkg" \
    "https://nodejs.org/dist/${NODE_LTS_VERSION}/node-${NODE_LTS_VERSION}.pkg" \
    "Node.js LTS ${NODE_LTS_VERSION}"

# NOTE: Docker Desktop (~600 MB) and Claude Desktop are NOT bundled.
# They are downloaded at runtime by Install-DevEnvironment.sh.

# ── Required bundle gate ───────────────────────────────────────────────────────
info "=== Verifying required bundle files ==="
REQUIRED=(
    "ME_nvm_install.sh"
    "ME_Node_LTS_mac.pkg"
    "ME_VS_Code_mac.zip:ME_Visual_Studio_Code_mac.zip"
    "ME_AWS_CLI_v2_mac.pkg"
    "ME_Python_3_12_mac.pkg"
)
MISSING=0
for entry in "${REQUIRED[@]}"; do
    # Support "label:filename" or just "filename"
    filename="${entry##*:}"
    [ -z "$filename" ] && filename="$entry"
    if [ ! -f "$BUNDLED_DIR/$filename" ]; then
        warn "MISSING required bundle file: $filename"
        MISSING=$((MISSING+1))
    fi
done
if [ $MISSING -gt 0 ]; then
    error "$MISSING required bundle file(s) missing — aborting zip creation."
fi
ok "All required bundle files present."

# ── Stamp Deploy and Rollback scripts with git hash ───────────────────────────
info "Stamping scripts with git hash: $GIT_HASH"
sed_inplace "s/GIT_COMMIT_HASH/$GIT_HASH/g" "$SCRIPT_DIR/Deploy-DevEnvironment.sh" 2>/dev/null || true
sed_inplace "s/GIT_COMMIT_HASH/$GIT_HASH/g" "$SCRIPT_DIR/Rollback-DevEnvironment.sh" 2>/dev/null || true
info "Restore stamped scripts after upload: git checkout -- mac/scripts/Deploy-DevEnvironment.sh mac/scripts/Rollback-DevEnvironment.sh"

# ── Generate VERSIONS.md ───────────────────────────────────────────────────────
info "Generating mac-VERSIONS.md..."
{
    echo "# Mac Bundled Installer Versions"
    echo ""
    echo "Built: $BUILD_DATE"
    echo "Commit: $GIT_HASH"
    echo ""
    echo "| Package | File | Size |"
    echo "|---------|------|------|"
    for f in "$BUNDLED_DIR"/ME_*.zip "$BUNDLED_DIR"/ME_*.pkg "$BUNDLED_DIR"/ME_*.sh "$BUNDLED_DIR"/ME_*.tar.gz; do
        [ -f "$f" ] || continue
        SIZE=$(du -sh "$f" | awk '{print $1}')
        echo "| $(basename "$f") | $(basename "$f") | $SIZE |"
    done
    echo ""
    echo "**Not bundled** (downloaded at runtime):"
    echo "- Docker Desktop  (~600 MB)"
    echo "- Claude Desktop  (DMG - direct download)"
    echo ""
    echo "Re-run Package-Release.sh before each deployment wave to refresh bundled versions."
} > "$VERSIONS_FILE"
ok "mac-VERSIONS.md written."

# ── Create zip ────────────────────────────────────────────────────────────────
info "Creating $ZIP_NAME..."
cd "$(dirname "$MAC_DIR")"
ZIP_SRC="mac"
rm -f "$ZIP_NAME"
make_zip "$ZIP_NAME" "$ZIP_SRC/scripts/" "$ZIP_SRC/bundled/"
ok "Created $ZIP_NAME ($(du -sh "$ZIP_NAME" | awk '{print $1}'))"

info ""
info "=== Next steps ==="
info "1. Upload zip + VERSIONS.md to GitHub release:"
info "   gh release upload v1.0 mac-setup-automation.zip mac-VERSIONS.md --clobber"
info "2. Restore stamped scripts:"
info "   git checkout -- mac/scripts/Deploy-DevEnvironment.sh mac/scripts/Rollback-DevEnvironment.sh"
info "3. Run NinjaOne automation on target Mac(s)."
