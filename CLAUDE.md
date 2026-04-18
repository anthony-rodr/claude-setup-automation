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
  - **Did NOT install in Run 2** — likely because Python failed first; pip has no Python to run against
- **Claude Desktop** (`Choco = 'claude'`, `DType = 'msix'`) — Choco primary, MSIX direct fallback from Anthropic CDN
  - MSIX handler uses `Add-AppxProvisionedPackage` (machine-wide, all users) not `Add-AppxPackage` (per-user, fails as SYSTEM)
  - **Not yet tested** — needs verification on next clean install run

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
- ~98% successful — everything installed correctly except Python
- Duration unknown — log files pending review
- Python failure theory: Python Launcher may need to be installed before Python 3.12
- **Await log files before drawing conclusions or making code changes**

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

## Next steps (as of 2026-04-18)
1. Rollback test machine — copy all logs to C:\projects\ for review
2. Analyze Run 2 install log to confirm Python failure root cause
3. Fix Python install and rollback based on log findings
4. Rebuild zip: run Package-Release.ps1 (bundled files already present, just rezipping scripts)
5. Upload: `gh release upload v1.0 claude-setup-automation.zip --clobber`
6. Run fresh install — verify Python, Keeper Commander, Claude Desktop
