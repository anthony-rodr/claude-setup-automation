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
   - Re-runs are fast: already-present files in `bundled/` are skipped (delete a file to force refresh)
   - **Also stamps** `Deploy-DevEnvironment.ps1` and `Rollback-DevEnvironment.ps1` in-place with `git rev-parse --short HEAD`
   - After copying stamped scripts to NinjaOne, restore placeholders: `git checkout -- scripts/Deploy-DevEnvironment.ps1 scripts/Rollback-DevEnvironment.ps1`
2. Commit changes and upload zip + VERSIONS.md to GitHub release:
   - Push via SSH only (HTTPS broken — libcurl DLL conflict from Docker/AWS CLI)
   - Remote: `git@github.com:anthony-rodr/claude-setup-automation.git`
   - SSH key: `C:\Users\adm_arodriguez\.ssh\id_ed25519`
   - Upload: `gh release upload v1.0 claude-setup-automation.zip VERSIONS.md --clobber`
3. NinjaOne runs `Deploy-DevEnvironment.ps1` on target machines — pulls zip from GitHub, extracts, runs installer as SYSTEM
4. **Deploy-DevEnvironment.ps1 and Rollback-DevEnvironment.ps1 are stored directly in NinjaOne** — must be updated there manually when changed

**NinjaOne deploy URL:**
`https://github.com/anthony-rodr/claude-setup-automation/releases/latest/download/claude-setup-automation.zip`

## Install architecture (runs on remote machines as SYSTEM)
Order of operations in `Install-DevEnvironment.ps1`:
1. **Bulk Choco install** — `choco install scripts/packages.config` for packages with NO bundled version
2. **Per-package loop** with skip-if-installed pre-check, then four tiers per package:
   - **Pre-check**: `VerifyCmd` (CLI command present) or `VerifyAppx` (MSIX provisioned) → skip entirely
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

## Skip-if-installed (VerifyCmd / VerifyAppx) — added session 7
All CLI packages now have `VerifyCmd` so they are skipped entirely (no download, no install)
if the command is already on PATH. Critical for redeployment to partially-configured machines.
| Package | VerifyCmd/VerifyAppx |
|---------|---------------------|
| Git | `git` |
| VS Code | `code` |
| PowerShell 7 | `pwsh` |
| nvm | `nvm` — especially important: zip-to-path would wipe existing node versions |
| Python 3.12 | `python` |
| GitHub CLI | `gh` |
| Docker Desktop | `docker` — reinstall resets settings |
| AWS CLI v2 | `aws` |
| Terraform | `terraform` |
| Claude Desktop | `VerifyAppx = '*Claude*'` — checks provisioned MSIX |

## Package notes
- **Keeper Commander** — **disabled 2026-04-20** (block-commented in Install-DevEnvironment.ps1)
  - pip install fails consistently: Zscaler blocks pypi.org at network level even after CA cert injection
  - Do NOT re-enable until KSM is licensed and a non-pip delivery method is available
- **Claude Desktop** — `DType = 'msix'`, uses `Add-AppxProvisionedPackage` (machine-wide)
  - `VerifyAppx = '*Claude*'` skips if already provisioned
  - Public desktop shortcut created by `Configure-UserEnvironment.ps1` via `Get-AppxPackage -AllUsers`

## Key design decisions
- **Python has `Choco = $null`** — choco python312 exits 1638 when registry remnants exist
- **Tier 0 exists** because Choco running before bundled installers leaves conflicting MSI state (caused Python 1638 failures during testing)
- **nvm has `Choco = $null` and `Winget = $null`** — choco nvm no-ops as SYSTEM, winget installs per-user; use nvm-noinstall.zip direct
- **WSL2 uses `wsl.exe --install`**, not Choco or winget
- **Claude Code installed via npm** to machine-wide prefix `C:\ProgramData\npm`
- **winget does NOT work as SYSTEM in NinjaOne** — stripped PATH; never use Start-Process winget directly; use Start-Job as fallback only
- **reg.exe must use full path** `$env:SystemRoot\System32\reg.exe` in SYSTEM sessions — bare `reg` fails

## Bundle version check
Deploy-DevEnvironment.ps1 fetches `VERSIONS.md` (~2 KB) from the release before downloading
the full zip. Skips 300+ MB download if versions match AND `Install-DevEnvironment.ps1` is
present in the extracted directory. Falls through to full download if either check fails.

## Run history
- Run 1 (2026-04-18): 19m 22s — 12/12, bulk Choco slow (bundled pkgs in packages.config — fixed)
- Run 2 (2026-04-18): ~13m — 11/12, Python failed (bootstrapper exits fast before child msiexec completes)
- Run 3 (2026-04-18): 17m 56s — 11/14, Python same failure, Claude Desktop per-user not provisioned
- Run 4 (2026-04-20): Python 3.12 INSTALLED, pip hung on Keeper (Zscaler blocked pypi.org)
- Run 5 (2026-04-20): pip still failed — CA cert injection works but Zscaler blocks at network level; Keeper disabled
- Run 6 (2026-04-20): **24m 43s — 12/12, 0 failures**; VS Code extensions confirmed, Claude installed; Claude public desktop shortcut missing (fixed in zip — needs redeploy)

## Rollback fixes (session 7, 2026-04-20) — commit f1328f8
- Added `bundled` switch case: routes to `Invoke-RegistryUninstall`; Terraform force-removes directory
- Added `pre-existing` switch case: skips silently, not flagged as error
- Claude Desktop: `Remove-AppxProvisionedPackage` + `Remove-AppxPackage -AllUsers` in `direct` handler
- Fixed `DisplayName` StrictMode crash in `direct` registry fallback
- WSL2: `wsl.exe --uninstall` instead of failing winget call
- `reg.exe` full path (`$env:SystemRoot\System32\reg.exe`) throughout
- Added `Claude.lnk` to public desktop cleanup list
- **NinjaOne rollback script still needs manual update** — target machines ran old version in last test

## Session 8 changes (2026-04-20)
- **Version stamp + staleness check** implemented in Deploy and Rollback:
  - `$ScriptVersion = 'GIT_COMMIT_HASH'` placeholder in both scripts
  - At startup: fetches GitHub API (`/commits/main`), compares 7-char SHA
  - Unstamped (live pull from GitHub): shows `[live — main @ <sha>]` green — no prompt
  - Stamped + current: shows `[<sha> — current]` green
  - Stamped + outdated: shows `[OUTDATED]` red + YES prompt (Deploy: `UserInteractive`; Rollback: `-Force`)
  - `Package-Release.ps1` step 10 stamps both scripts after zip build for NinjaOne stored-script workflow
- **User notifications via `msg.exe`** added to all three scripts:
  - Deploy startup: *"IT Update: Developer tools are being deployed… 15-30 minutes… save your work — restart may be required"*
  - Rollback startup: *"IT Update: Developer tools are being removed… few minutes… save your work — restart may be required"*
  - Install completion: *"IT Update: Developer tool installation is complete. If a service is not working, please restart."*
- **Live-from-GitHub workflow confirmed**: user downloads script fresh from raw GitHub each run via NinjaOne PS terminal — always current, no NinjaOne stored script needed
- **Rollback partial run (2026-04-20)**: old cached script in TEMP ran instead of freshly downloaded one (filename mismatch in download command). Bundled tools not uninstalled. Claude Code and nvm removed. Needs re-run with corrected command.
- **GIT_COMMIT_HASH placeholder bug fixed**: accidentally committed as `d3e9bb7` in commit `001a885`, causing live pulls to show OUTDATED. Restored in `6b81d18`.

## Known issues / open items
- **Rollback needs re-run**: bundled tools (VS Code, Git, AWS CLI, GitHub CLI, Python, Terraform) still installed on test machine after partial old-script run — re-run rollback with correct download command
- **Claude Desktop rollback unverified**: MSIX removal not explicitly checked post-rollback
- **Python rollback**: no uninstall string in registry for machine-wide Python; fix: use bundled `ME_Python_3_12.exe /quiet /uninstall`
- **Claude Desktop shortcut**: not appearing on public desktop — requires new zip with Configure-UserEnvironment.ps1 changes
- WSL2 cannot be removed without a reboot
- libcurl DLL conflict (from Docker/AWS CLI) breaks git HTTPS — always use SSH for pushes
- **fix-encoding.ps1**: appends extra blank lines to unchanged PS1 files each run — minor nuisance
- KSM licensing needed for Keeper Commander re-enable

## Dev machine state (as of session 8, 2026-04-20)
- Keeper Commander installed on dev machine: `C:\Python314\Scripts\keeper.exe`
- SSH key pair: Windows ssh-agent service set to Automatic; PS profile loads key at login
- PS profile: `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- Keeper login works (Zscaler CA appended to `C:\Python314\Lib\site-packages\certifi\cacert.pem`)
- Keeper uses SSO — non-interactive access requires KSM (not licensed yet)

## Next steps (as of 2026-04-20 session 8)
1. **Re-run rollback** on test machine with correct download command (save to matching filename):
   ```
   $rb = "$env:TEMP\Rollback-DevEnvironment.ps1"
   Invoke-WebRequest "https://raw.githubusercontent.com/anthony-rodr/claude-setup-automation/main/scripts/Rollback-DevEnvironment.ps1" -OutFile $rb -UseBasicParsing
   powershell.exe -ExecutionPolicy Bypass -File $rb
   ```
2. **Verify Claude Desktop MSIX removed** after rollback: `Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*Claude*' }`
3. **Rebuild zip** (`Package-Release.ps1` + upload) to pick up Install-DevEnvironment.ps1 completion notification
4. Fix Python rollback: use bundled `ME_Python_3_12.exe /quiet /uninstall`
5. Request KSM licensing from Keeper admin
