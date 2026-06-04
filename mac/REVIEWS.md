---
phase: mac-setup-scripts
reviewers: [claude-self-review]
reviewed_at: 2026-05-05T18:40:00Z
external_reviewers_attempted: [gemini (auth missing — needs GEMINI_API_KEY), codex (auth missing — needs OPENAI_API_KEY)]
plans_reviewed:
  - mac/ninjaone/NinjaOne-Bootstrap.sh
  - mac/scripts/Deploy-DevEnvironment.sh
  - mac/scripts/Install-DevEnvironment.sh
  - mac/scripts/Configure-UserEnvironment.sh
  - mac/scripts/Package-Release.sh
  - mac/scripts/Rollback-DevEnvironment.sh
---

# Cross-AI Plan Review — Mac Setup Scripts

> External CLIs (Gemini, Codex) could not be invoked — API keys not configured.
> Review conducted by Claude Code with adversarial self-review discipline.
> To get independent reviews: `gsd-sdk config set review.models.gemini gemini-2.5-pro` + set `GEMINI_API_KEY`.

---

## Claude Self-Review

### Summary

The Mac automation scripts faithfully mirror the Windows 3-tier architecture and make the right
high-level decisions (brew-as-non-root, arch detection, system-wide npm prefix, pkg-first install
tiers). However, there are several correctness bugs — primarily around PIPESTATUS propagation
through pipes, nvm verification, Docker rollback paths, and the Homebrew NONINTERACTIVE env var
not surviving sudo — that would cause silent failures or incorrect status reporting on a real run.
The scripts are a strong starting point but should not be deployed without fixes to the HIGH-severity
items below.

---

### Strengths

- **Brew-as-non-root is handled correctly** — console user detection with `stat -f '%Su' /dev/console`
  plus fallback to first UID ≥500 account covers both interactive and headless NinjaOne scenarios.
- **4-tier install fallback** (bundled → direct download → brew cask → brew formula) matches the
  Windows pattern and gives good resilience against network or packaging issues.
- **Arch detection is correct** — `uname -m` arm64 vs x86_64 branch covers Apple Silicon vs Intel
  throughout all six scripts consistently.
- **Lock file mutex** in Bootstrap prevents concurrent NinjaOne runs, matching the Windows mutex.
- **VERSIONS.md staleness check** avoids re-downloading the 400MB+ zip on re-runs.
- **Manifest + verify reports** give the same observability as the Windows equivalent.
- **Rollback has `--dry-run`** — safer than the Windows rollback which has no preview mode.
- **`set -uo pipefail`** without `-e` is the right choice: prevents undefined var bugs and broken
  pipes without causing unexpected exits from recoverable failures.

---

### Concerns

**HIGH — `install_pkg` loses the installer exit code through the pipe**

```bash
invoke_with_timeout 600 installer -pkg "$pkg_path" -target / -verboseR 2>&1 | \
    tail -5 | while read -r line; do log_info "  PKG: $line"; done
return ${PIPESTATUS[0]}
```

`${PIPESTATUS[0]}` captures the exit code of `invoke_with_timeout` from the most recently executed
pipeline. BUT: inside `install_pkg`, the `return` is called after the `if [ "$is_cask" = "true" ]`
block, not immediately after the pipe. The `fi` statement itself is not a pipeline command, so
`PIPESTATUS` IS the array from the preceding pipeline. This is actually correct — **but only when
`install_pkg` is called in an `if` condition context** (which suspends `set -e` for the entire
function, allowing the pipe to complete without early exit). If `install_pkg` is ever called bare
(not in an `if`), `pipefail` could kill the script before `PIPESTATUS` is read. Recommend capturing
explicitly:

```bash
invoke_with_timeout 600 installer -pkg "$pkg_path" -target / -verboseR 2>&1 | \
    tail -5 | while read -r line; do log_info "  PKG: $line"; done
local rc=${PIPESTATUS[0]}
return $rc
```

**HIGH — `NONINTERACTIVE=1` does not survive `sudo` to the Homebrew install**

```bash
NONINTERACTIVE=1 sudo -u "$CONSOLE_USER" bash "$install_script"
```

`sudo` resets the environment by default (`env_reset` in `/etc/sudoers`). `NONINTERACTIVE=1` is
set in the outer env but stripped before the subprocess sees it. Homebrew will show an interactive
license prompt that hangs forever on a headless NinjaOne run. Fix:

```bash
sudo -u "$CONSOLE_USER" env NONINTERACTIVE=1 bash "$install_script"
```

**HIGH — `verify_cmd nvm` always reports FAIL even when nvm is installed**

`nvm` is a shell function, not a binary. `command -v nvm` and `[ -x "$BREW_PREFIX/bin/nvm" ]`
both return false regardless of whether nvm is installed. The verify report will always print
`[FAIL] nvm — not found on PATH` even after a successful install. Fix:

```bash
# Replace "nvm:nvm" in the verify loop with a file check:
[ -f "$NVM_DIR/nvm.sh" ] && echo "  [OK]   nvm — installed at $NVM_DIR" || echo "  [FAIL] nvm — nvm.sh missing"
```

**HIGH — Docker rollback uses `$HOME` (root's home) instead of user homes**

```bash
rm -rf "$HOME/.docker" 2>/dev/null || true
rm -rf "/Library/Application Support/com.docker.docker" 2>/dev/null || true
```

`$HOME` in a root-running script is `/var/root`, not the console user's home. Docker Desktop
stores user config in `~/Library/Application Support/Docker` and `~/.docker` in each user's home.
The rollback leaves user Docker config behind. Fix:

```bash
for user_home in /Users/*/; do
    rm -rf "$user_home/.docker" 2>/dev/null || true
    rm -rf "$user_home/Library/Application Support/Docker" 2>/dev/null || true
done
```

**MEDIUM — DMG mount should use `-noquarantine` to avoid Gatekeeper blocks**

```bash
hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse -quiet
```

Downloaded DMGs get quarantine extended attributes. Without `-noquarantine`, hdiutil may prompt
for Gatekeeper approval or silently fail on macOS 14+. Fix:

```bash
hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse -quiet -noquarantine
```

Also add quarantine removal from copied apps:
```bash
xattr -r -d com.apple.quarantine "/Applications/$app_name" 2>/dev/null || true
```

**MEDIUM — `bash_completion` sourced in `.zshrc` (wrong shell)**

In `Configure-UserEnvironment.sh`, the shell block appended to `.zshrc` includes:

```bash
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
```

`bash_completion` is a bash-specific file. Sourcing it in zsh silently fails or produces errors.
macOS default shell is zsh since Catalina. Remove this line from the zshrc block (it's harmless
in `.bash_profile` only).

**MEDIUM — `install_git` Xcode CLT install is a GUI dialog; polling may deadlock headless**

`xcode-select --install` launches a GUI "Software Update" dialog. On a headless NinjaOne
deployment with no desktop session, the dialog never appears and `verify_cmd git` never becomes
true. The poll runs for 600 seconds and wastes 10 minutes before falling back to brew. The correct
headless approach:

```bash
# Headless CLT install via softwareupdate
PROD=$(softwareupdate -l 2>&1 | grep -m1 "Command Line Tools" | awk 'NF>1{print $NF}' || echo "")
if [ -n "$PROD" ]; then
    invoke_with_timeout 600 softwareupdate -i "$PROD" --verbose
fi
```

**MEDIUM — GitHub CLI bundled file name mismatch**

`Package-Release.sh` downloads two separate files:
```
ME_GitHub_CLI_arm64.tar.gz
ME_GitHub_CLI_amd64.tar.gz
```

But `Install-DevEnvironment.sh` looks for a single bundled file:
```bash
local bundle="$BUNDLED_DIR/ME_GitHub_CLI_mac.tar.gz"
```

That filename doesn't exist — the install Tier 1 will always miss and fall through to direct
download. Either consolidate to a single universal bundle or add arch-specific lookup:
```bash
local bundle="$BUNDLED_DIR/ME_GitHub_CLI_$(uname -m | sed 's/x86_64/amd64/;s/arm64/arm64/').tar.gz"
```

**MEDIUM — Similarly for Terraform and PowerShell 7 bundled file names**

`Package-Release.sh` creates `ME_Terraform_arm64_mac.zip` and `ME_Terraform_amd64_mac.zip`, but
`Install-DevEnvironment.sh` looks for `ME_Terraform_mac.zip`. Same mismatch as GitHub CLI above.
Same fix: use arch-specific lookup or rename to a unified file.

`ME_PowerShell_7_arm64_mac.pkg` / `ME_PowerShell_7_amd64_mac.pkg` vs `ME_PowerShell_7_mac.pkg`.
Same issue.

**MEDIUM — nvm install script modifies root's shell profile, not user's**

When `install_nvm_and_node` runs `NVM_DIR="$NVM_DIR" bash "$bundle"`, nvm's install script
tries to modify the shell profile of the *current user* (root), appending `export NVM_DIR` and
source lines to `/root/.zshrc` or `/root/.bashrc`. These changes are useless (root's profile is
irrelevant) and do not affect end users. `Configure-UserEnvironment.sh` correctly adds the sourcing
to each user's `~/.zshrc`, so the end state is correct — but the nvm install script output will
report that it configured `/root/.zshrc`, which is confusing. No functional bug, but worth noting
in documentation.

**LOW — `printf '=%.0s' {1..64}` brace expansion in `$()`**

```bash
echo "$(printf '=%.0s' {1..64})"
```

Brace expansion inside a `$()` subshell is non-standard in some `sh` implementations. Since
these scripts use `#!/bin/bash`, this works on macOS — but if ever run under `/bin/sh` (not bash),
it would fail. Not a real issue given the shebang, but low-risk to rewrite as:
```bash
printf '%0.s=' {1..64}; echo
```

**LOW — `Package-Release.sh` uses `sed -i ''` (macOS only)**

The `-i ''` flag is macOS `sed` syntax and will fail on Linux. Since `Package-Release.sh` is
only ever run on a Mac (to build the Mac package), this is fine but worth a comment.

**LOW — Rollback `pkgutil --forget` does not actually remove files**

`pkgutil --forget` only removes the package receipt from the database — it does NOT uninstall
the files. The rollback script relies on manually removing known paths (`/Library/Frameworks/...`,
binaries, etc.) after forgetting the receipt. For Python and AWS CLI, the known paths are correct.
For PowerShell, the removal of `/usr/local/bin/pwsh` and `/Applications/PowerShell.app` covers the
common case. Add a comment in the rollback script explaining that `--forget` is cosmetic.

**LOW — No Zscaler CA injection step**

The Windows installer has Zscaler CA cert injection (critical for pypi.org, Homebrew, etc. at
Master Electronics). The Mac scripts have no equivalent. On target machines behind Zscaler, every
`curl` download and `brew install` will fail with TLS errors. This should be addressed before
any real deployment. Reference the Windows approach in `Install-DevEnvironment.ps1` for how
the cert injection was handled there.

---

### Suggestions

1. **Fix bundled file name mismatches first** (GitHub CLI, Terraform, PowerShell) — these are
   pure typos that will cause every bundled install to miss silently. Easy fix, high impact.

2. **Add a `test_install` dry-run mode** — similar to `--dry-run` on rollback. Running `bash
   Install-DevEnvironment.sh --dry-run` should print what it WOULD do without changing anything.
   Invaluable for testing without a target Mac.

3. **Add Zscaler CA injection** before any network calls — check if `/Library/Managed Preferences`
   or `security find-certificate` can find the ME root CA, then inject into curl's CA bundle.

4. **Sign the downloaded DMGs before mounting** — add `spctl --assess --type open` or `codesign
   --verify` calls after download to catch tampered files.

5. **Use `softwareupdate` for Xcode CLT** instead of the GUI `xcode-select --install` for headless
   reliability.

6. **Consider bundling both arch variants of Terraform, GitHub CLI, and PowerShell** in a single
   universal file (or use a consistent naming scheme and select at runtime).

7. **Add a `--test-connection` pre-flight** at start of Install — verify GitHub release URL is
   reachable before attempting installs that need network fallback. Log clearly if network is
   blocked (Zscaler scenario).

---

### Risk Assessment: **MEDIUM-HIGH**

The architecture is sound and mirrors the battle-tested Windows approach. The HIGH-severity bugs
(NONINTERACTIVE not surviving sudo, nvm verify always failing, Docker rollback wrong home, bundled
file name mismatches) would cause visible failures on first real deployment. None of them are
showstoppers that prevent the install from completing, but they produce incorrect status reports,
miss bundled installs, and leave Docker config behind on rollback. Fix the HIGH items before any
production deployment. The Zscaler CA injection gap is the single biggest risk for Master
Electronics' network environment — the Windows scripts explicitly handled this and the Mac scripts
don't yet.

---

## Consensus Summary

*(Single reviewer — no consensus possible. Items to prioritize before first test run:)*

### Top Priorities Before First Test

1. Fix bundled file name mismatches (GitHub CLI, Terraform, PowerShell) — HIGH
2. `NONINTERACTIVE=1` through sudo for Homebrew install — HIGH
3. `verify_cmd nvm` always reports FAIL — HIGH
4. Docker rollback `$HOME` should be per-user — HIGH
5. DMG `-noquarantine` flag — MEDIUM
6. `bash_completion` in `.zshrc` — MEDIUM
7. Zscaler CA injection — MEDIUM (network-blocking for ME environment)

### Items to Address Before Production

- Headless Xcode CLT via `softwareupdate`
- `install_pkg` explicit PIPESTATUS capture
- Code signing verification for downloaded DMGs
- `--dry-run` / `--test-connection` flags

---

*To get independent AI reviews once auth is configured:*
- `$env:GEMINI_API_KEY = "..."` then re-run `/gsd-review`
- `$env:OPENAI_API_KEY = "..."` for Codex

---

## Fixes Applied (2026-06-03)

Worked the prioritized list above. All scripts pass `bash -n` after these changes
(shellcheck not available on the dev machine, so only syntax was statically verified —
no real macOS run yet).

| # | Item | Severity | Status | Where |
|---|------|----------|--------|-------|
| 1 | Bundled file-name mismatch (GitHub CLI, Terraform, PowerShell 7) | HIGH | ✅ Fixed | `Install-DevEnvironment.sh` — Tier 1 now derives arch suffix (`arm64`/`amd64`) to match the `ME_<pkg>_<arch>*` names `Package-Release.sh` ships |
| 2 | `NONINTERACTIVE=1` stripped by `sudo` (Homebrew hangs headless) | HIGH | ✅ Fixed | `install_homebrew` → `sudo -u "$CONSOLE_USER" env NONINTERACTIVE=1 bash …` |
| 3 | `verify_cmd nvm` always FAILs (nvm is a shell function) | HIGH | ✅ Fixed | verify report now checks `$NVM_DIR/nvm.sh` by file, removed from PATH loop |
| 4 | Docker/Claude rollback used root's `$HOME` | HIGH | ✅ Fixed | `Rollback-DevEnvironment.sh` — both now iterate `/Users/*/` |
| 5 | DMG Gatekeeper quarantine | MED | ✅ Fixed | `install_dmg` adds `hdiutil … -noquarantine` + `xattr -r -d com.apple.quarantine` on the copied app |
| 6 | `bash_completion` sourced under zsh | MED | ✅ Fixed | `Configure-UserEnvironment.sh` — guarded on `[ -n "$BASH_VERSION" ]` |
| 7 | Headless Xcode CLT (GUI dialog never appears) | MED | ✅ Fixed | `install_git` now uses the `softwareupdate -l`/`-i <label>` sentinel-file method |
| 8 | `install_pkg`/`brew_install` PIPESTATUS capture | MED | ✅ Fixed | both capture `local rc=${PIPESTATUS[0]}` before `return` |
| — | `for f in …{a,b} 2>/dev/null` parse error (pre-existing) | — | ✅ Fixed | `Package-Release.sh` VERSIONS.md loop — invalid redirect on a `for` list; split into separate globs |

### Still open

- **Zscaler CA injection (MED)** — deferred pending ME-specific cert details. On macOS, curl/git use
  the System keychain via Secure Transport, so if MDM already pushes the Zscaler root CA to the
  **System keychain**, those likely already trust it. The real gaps are **Node** (`NODE_EXTRA_CA_CERTS`)
  and **pip** (certifi / `PIP_CERT`). Needs a decision on how the cert is delivered before wiring in.
- Code-signing verification for downloaded DMGs (LOW suggestion)
- `--dry-run` / `--test-connection` flags for Install (suggestion)
- No real macOS test run yet — all verification so far is static (`bash -n`).

---

## Claude Code → native binary (2026-06-03)

Claude Code is no longer installed via npm. `install_claude_code` was rewritten to mirror the
proven Windows approach (commit `95adaaa` on the Windows side):

- **Tier 1** — direct CDN download from `https://downloads.claude.ai/claude-code-releases`
  (`/latest` → `/$ver/manifest.json` for the SHA256 → `/$ver/<darwin-arm64|darwin-x64>/claude`),
  checksum-verified, installed **machine-wide** to `/usr/local/bin/claude`. No Node/npm.
- **Tier 2** — official native install script `curl https://claude.ai/install.sh | bash` run as
  the console user (per-user `~/.local/bin`, symlinked machine-wide). Still no Node.
- **npm tier removed entirely** on macOS.
- Manifest method is now `native` / `native-script`; `Rollback-DevEnvironment.sh` updated to remove
  `/usr/local/bin/claude` + per-user `~/.local/{bin,share}/claude` (keeps legacy npm cleanup for
  older deployments).
- Verified: CDN reachable, both darwin URLs return 206, grep checksum-parse (no jq) matches manifest,
  `bash -n` clean. Not yet run on a real Mac.

### Knock-on effects
- **Claude Code no longer depends on nvm/Node** on macOS (Node stays as a general dev tool, but it's
  no longer on the Claude Code critical path).
- **Zscaler / NODE_EXTRA_CA_CERTS reassessed**: the native binary trusts the macOS System keychain
  by default (`CLAUDE_CODE_CERT_STORE=bundled,system`), so Claude Code works behind Zscaler with **no**
  cert env var. `NODE_EXTRA_CA_CERTS` is now only relevant for **npm** (dev installs) and the **VS Code
  marketplace**, and `PIP_CERT`/`AWS_CA_BUNDLE` for pip/AWS — all lower priority than the Claude path was.

### Windows npm tier — removed (2026-06-03, per user)
Decision: Claude Code must not be installed by node/npm on either platform, but **nvm/Node/npm stay
installed as dev tools**.
- Removed the npm Tier-2 fallback from `Install-ClaudeCode` (Windows). Native CDN download is now the
  sole method, wrapped in a `$MaxRetries` retry loop to keep the resilience the npm tier provided.
- Node/npm still installed: `Install-NodeThroughNvm` runs in the main flow (line ~1821), independent
  of Claude Code — verified, so removing the npm tier does **not** stop Node/npm from installing.
- The npm tier had a **transient** `$env:NODE_EXTRA_CA_CERTS` export (process-scoped, only for the
  now-removed install-time npm install of Claude; never persisted). Removing the tier removed that.
- Windows script parses clean (PowerShell AST parser); `CLAUDE.md` updated to match.

### Windows Zscaler cert env — implemented properly (2026-06-03)
Discovered while removing the npm tier: `NODE_EXTRA_CA_CERTS` was **never persisted** anywhere in the
Windows installer — the only set was the transient one above, so end-user npm / VS Code marketplace /
pip behind Zscaler were never actually fixed. `Test-DevEnvironment.ps1` (L376–428) was already written
to expect a persisted setup and would have graded it **FAIL**. Added a dedicated `Set-ZscalerCertEnv`
step (runs before the package loop, independent of Claude):
- Writes two files under `C:\ProgramData\ZscalerCA\`:
  - `zscaler-root-ca.pem` — Zscaler-only (the standard path the health-check validates).
  - `ca-bundle.pem` — **combined bundle = complete public roots + Zscaler**, so tools verify TLS
    **on AND off** the Zscaler network (requirement from the user). Public-root base = certifi's full
    Mozilla set (vendored with pip, present once Python installs — same pattern as the dev machine);
    falls back to a Windows `LocalMachine\Root` export if certifi isn't found. Emitted as canonical
    PEM (cert blocks only, via regex) so it also passes `Test-PemFile`'s first-line check.
- Persists `NODE_EXTRA_CA_CERTS`, `PIP_CERT`, `AWS_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`
  → the **combined** bundle, at **Machine** scope (inherited by all users/processes) + current session
  (so the VS Code marketplace works during install).
- Runs **after the package loop** (so Python/certifi exist), before Node/Claude/Configure. No-ops
  cleanly if no Zscaler root is present.
- Verified: PowerShell AST parses clean; simulated certifi-with-comments + Zscaler → 2 blocks,
  bundle first line is `-----BEGIN CERTIFICATE-----`, `Test-PemFile` passes.
- **macOS parity not yet done** — same gap exists for mac npm/pip (Claude Code native is unaffected).
