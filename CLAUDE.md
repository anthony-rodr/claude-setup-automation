# Claude Code — Project Context

## What this project is
Automated developer environment installer for Master Electronics.
Scripts are deployed via **NinjaOne RMM** and run on **remote employee machines as SYSTEM**.
This is NOT run on the dev machine. Never confuse the two.

## Machines involved
- **Dev machine** (adm_arodriguez, C:\projects\claude-setup-automation): write code, build zip, push to GitHub only
- **Test/target machines**: separate remote computers where the installer actually runs as SYSTEM via NinjaOne

## Deployment workflow
1. Run `scripts/Package-Release.ps1` on the DEV machine — downloads bundled installers into `bundled/`, builds `claude-setup-automation.zip`
2. Commit changes and upload zip to GitHub release:
   - Push via SSH only (HTTPS broken — libcurl DLL conflict from Docker/AWS CLI)
   - Remote: `git@github.com:anthony-rodr/claude-setup-automation.git`
   - SSH key: `C:\Users\adm_arodriguez\.ssh\id_ed25519`
   - Upload: `gh release upload v1.0 claude-setup-automation.zip --clobber`
3. NinjaOne runs `Deploy-DevEnvironment.ps1` on target machines — pulls zip from GitHub, extracts, runs installer as SYSTEM

**NinjaOne deploy URL:**
`https://github.com/anthony-rodr/claude-setup-automation/releases/latest/download/claude-setup-automation.zip`

## Install architecture (runs on remote machines as SYSTEM)
Order of operations in `Install-DevEnvironment.ps1`:
1. **Bulk Choco install** — `choco install scripts/packages.config` for packages with NO bundled version
2. **Per-package loop** with four tiers per package:
   - **Tier 0**: Bundled installer in `bundled/` — local, no network, fastest
   - **Tier 1**: Chocolatey fallback
   - **Tier 2**: Direct download fallback
   - **Tier 3**: winget (last resort — unreliable as SYSTEM)
3. **Parallel profile config** — all existing user profiles configured simultaneously via Start-Job (~74s vs 13min sequential)

## What's bundled (Package-Release.ps1 downloads these)
Ships inside the zip — no network needed on target machine:
| File | Package |
|------|---------|
| `ME_Visual_Studio_Code.exe` | VS Code |
| `ME_Git_for_Windows.exe` | Git for Windows |
| `ME_AWS_CLI_v2.msi` | AWS CLI v2 |
| `ME_Python_3_12.exe` | Python 3.12 |
| `ME_GitHub_CLI.msi` | GitHub CLI |
| `ME_Terraform.zip` | Terraform |

**Not bundled** (size trade-off — Choco downloads at install time):
- Docker Desktop (~600 MB) — Choco + direct fallback
- PowerShell 7 (~100 MB) — Choco + direct fallback

## packages.config (Choco bulk list — non-bundled packages only)
Only lists packages with NO bundled installer: `powershell-core`, `docker-desktop`, `claude`
Bundled packages (git, vscode, gh, awscli, terraform) are intentionally excluded — they use
Tier 0 (local) first, Choco only if that fails. Putting them in packages.config caused Choco
to download them from the internet before Tier 0 could run (~7 min wasted per deployment).

## New packages added (session 4)
- **Keeper Commander** (`DType = 'pip'`, `PipPkg = 'keepercommander'`) — pip install via machine Python 3.12
  - Did NOT install in Run 2 because Python failed first (no Python = no pip)
  - Fixed in session 5: Python now refreshes session PATH (root + Scripts\) after install
  - **Not yet tested on target machines** — needs Run 3
- **Claude Desktop** (`Choco = 'claude'`, `DType = 'msix'`) — Choco primary, MSIX direct fallback from Anthropic CDN
  - MSIX handler uses `Add-AppxProvisionedPackage` (machine-wide, all users) not `Add-AppxPackage` (per-user, fails as SYSTEM)
  - **Not yet tested** — needs Run 3

## Key design decisions
- **Python has `Choco = $null`** — choco python312 exits 1638 when registry remnants exist
- **Tier 0 exists** because Choco running before bundled installers leaves conflicting MSI state (caused Python 1638 failures during testing)
- **nvm has `Choco = $null` and `Winget = $null`** — choco nvm no-ops as SYSTEM, winget installs per-user; use nvm-noinstall.zip direct
- **WSL2 uses `wsl.exe --install`**, not Choco or winget
- **Claude Code installed via npm** to machine-wide prefix `C:\ProgramData\npm`
- **Claude needed a reboot** on first test — PATH changes require new session (expected, not a bug)
- **VS Code shortcut shows 2/3** — VS Code installer creates its own Public Desktop shortcut, per-user copy correctly skipped

## Test run results

### Run 1 (2026-04-18, old scripts)
- Duration: **19 min 22 sec** — 12/12 packages, 0 failures
- Bulk Choco was ~9 min (was downloading bundled packages — fixed in packages.config)
- Claude required reboot before working (expected). VS Code extensions confirmed present.

### Run 2 (2026-04-18, current scripts — packages.config fix applied)
- 11/12 packages installed — only Python failed (cascaded to Keeper Commander)
- Duration: ~13 min (verify-install timestamp: 14:53, bulk Choco started ~14:40)
- **Root causes confirmed from logs (session 5):**
  - Python EXE installer exits 0 in ~3 seconds — bootstrapper spawns child msiexec and exits; script moved on before Python files landed. `C:\Program Files\Python312\` never created.
  - msiexec exit 1619 on bundled GitHub CLI and AWS CLI MSIs — unresolved `..` in path passed to msiexec.exe. Both fell through to Choco successfully (not a real failure).
  - Keeper Commander: correctly skipped — Python not found at any AltPath or Scripts\ location
- **Fixes applied and pushed (commits ea35ecc, 11620e9):**
  - Python: poll AltPaths up to 90s after EXE exits; throw if python.exe never appears; refresh session PATH (root + Scripts\) on success
  - msiexec: resolve path with GetFullPath() before calling msiexec
  - Verify: added Keeper Commander + Claude Desktop checks, duration in summary

## Known issues / open items
- **Python install fails (Run 2)** — root cause unknown pending log review.
  Theory: Python Launcher ordering. Do NOT fix until logs confirm cause.
- **Python rollback fails**: Registry uninstall string missing for machine-wide Python install.
  Rollback falls back to winget which also fails. Python files survive rollback.
  Fix needed: use bundled `ME_Python_3_12.exe /quiet /uninstall` in rollback script.
- **VS Code rollback**: Earlier runs used force-remove only (left registry entries). Now uses
  `choco uninstall vscode` + force-remove — should be clean.
- AWS CLI choco uninstall times out in rollback — force cleanup handles it
- WSL2 cannot be removed without a reboot
- Rollback verification is PATH-only — can miss off-PATH installs
- libcurl DLL conflict (from Docker/AWS CLI) breaks git HTTPS — always use SSH for pushes
- PSScriptAnalyzer warnings in Install-DevEnvironment.ps1 (pre-existing):
  Ensure-Winget, Ensure-Chocolatey, Configure-ExistingProfiles use unapproved verbs; unused $launcherSrc; $null comparison side

## Dev machine state (as of session 5, 2026-04-18)
- Keeper Commander installed on dev machine: `C:\Python314\Scripts\keeper.exe`
- SSH key pair rotated (old key compromised in terminal — new key generated and added to GitHub)
- Both keys stored in Keeper vault record "GitHub SSH Key (DEV)"
- Private key file still on disk at `~\.ssh\id_ed25519` — DO NOT DELETE until ssh-agent setup confirmed
- **Keeper login issue**: Zscaler SSL inspection blocks `keeper login` — had to disable Zscaler temporarily. Fix needed: add Zscaler root CA to Python certifi bundle (next session)

## Next steps (as of 2026-04-18)
1. Run `.\scripts\Package-Release.ps1` on dev machine to rebuild zip
2. `gh release upload v1.0 claude-setup-automation.zip --clobber`
3. Run 3 on test machine — verify Python (~60s install), Keeper Commander, Claude Desktop
4. Fix Keeper login Zscaler issue: export Zscaler root CA → append to certifi bundle
5. Set up Keeper SSH agent → verify git push works → delete `~\.ssh\id_ed25519` from disk
6. Fix Python rollback: use `ME_Python_3_12.exe /quiet /uninstall` instead of winget
