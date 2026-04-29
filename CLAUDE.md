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
Order of operations in `Install-DevEnvironment.ps1` (replaced session 10 with ChatGPT rewrite):
1. **No bulk Choco** — per-package loop handles everything with `Invoke-Process` timeouts
2. **Per-package loop** with skip-if-installed pre-check, then four tiers per package (SYSTEM order):
   - **Pre-check**: `VerifyExe` (file exists), then `VerifyCmd` (CLI on PATH), then `VerifyAppx` (MSIX provisioned) → skip entirely
   - **Tier 1**: Bundled installer in `bundled/` — local, no network, fastest
   - **Tier 2**: Direct download
   - **Tier 3**: Chocolatey (900s timeout via `Invoke-Process`)
   - **Tier 4**: winget (last resort — unreliable as SYSTEM)
3. **nvm + Node installed as required** — `Install-NodeThroughNvm` called by `Install-ClaudeCode`; failure blocks Claude Code
4. **Claude Code** installed via `npm install -g` to `C:\ProgramData\npm`
5. **Parallel profile config** — up to 3 user profiles configured simultaneously via Start-Job
6. **Startup + completion `msg.exe` notifications** via `Send-UserNotification` helper

### Key architectural details of new script (session 10)
- `$TempDir = C:\ProgramData\MasterElectronics\DevSetup\Temp` — stable, created at startup (fixes TEMP missing)
- `Invoke-Process` wrapper with configurable timeout on every child process — nothing hangs forever
- `VerifyExe` on PowerShell 7 (`C:\Program Files\PowerShell\7\pwsh.exe`) — catches ghost Choco registrations
- Post-install hard verify — if VerifyExe defined and file missing after reported success → re-mark as failed
- Manifest SchemaVersion 1.1 — adds separate `Errors` and `Warnings` lists; Rollback ignores new fields (compatible)
- WSL2 exit codes 0, 1, and 3010 all treated as success

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

**Not bundled** (size trade-off — Choco/direct downloads at install time):
- Docker Desktop (~600 MB) — Choco + direct fallback
- PowerShell 7 (~100 MB) — Choco (with 900s timeout) + direct MSI fallback

## packages.config (Choco bulk list)
As of session 10, the new `Install-DevEnvironment.ps1` does **not use packages.config** — no bulk Choco at all.
The file still exists in the zip (listed in the expected layout) but is unused.
- `powershell-core` was removed session 9 — hung 52 min in SYSTEM context
- docker-desktop is handled by the per-package loop with `Invoke-Process` 900s timeout

## Skip-if-installed (VerifyCmd / VerifyExe / VerifyAppx)
All packages have at least one pre-check so they are skipped entirely on already-configured machines.
| Package | Check |
|---------|-------|
| Git | `VerifyCmd = 'git'` |
| VS Code | `VerifyCmd = 'code'`, `VerifyExe = 'C:\Program Files\Microsoft VS Code\Code.exe'` |
| PowerShell 7 | `VerifyCmd = 'pwsh'`, `VerifyExe = 'C:\Program Files\PowerShell\7\pwsh.exe'` (added session 9) |
| nvm | `VerifyCmd = 'nvm'` — zip-to-path would wipe existing node versions |
| Python 3.12 | `VerifyCmd = 'python'` |
| GitHub CLI | `VerifyCmd = 'gh'` |
| Docker Desktop | `VerifyCmd = 'docker'` — reinstall resets settings |
| AWS CLI v2 | `VerifyCmd = 'aws'` |
| Terraform | `VerifyCmd = 'terraform'` |
| Claude Desktop | `VerifyAppx = '*Claude*'` — checks provisioned MSIX |

## Package notes
- **Keeper Commander** — **disabled 2026-04-20** (block-commented in Install-DevEnvironment.ps1)
  - pip install fails consistently: Zscaler blocks pypi.org at network level even after CA cert injection
  - Do NOT re-enable until KSM is licensed and a non-pip delivery method is available
- **Claude Desktop** — `DType = 'msix'`, uses `Add-AppxProvisionedPackage` (machine-wide)
  - `VerifyAppx = '*Claude*'` skips if already provisioned
  - Public desktop shortcut created by `Configure-UserEnvironment.ps1` via `Get-AppxPackage -AllUsers`
- **PowerShell 7** — Choco `powershell-core` can hang indefinitely in SYSTEM context. Removed from bulk install.
  The per-package Choco call has a 900s timeout and falls through to direct GitHub MSI download.
  `VerifyExe` ensures ghost Choco registrations (files missing but Choco thinks installed) are caught.

## Key design decisions
- **No bulk Choco at all** — per-package `Invoke-Process` with 900s timeout; `powershell-core` hung 52 min in Run 7 under bulk call
- **`$TempDir` = stable ProgramData path** — SYSTEM's `AppData\Local\Temp` may not exist on newly provisioned machines
- **Tier 0 (bundled) exists** — Choco before local files caused conflicting MSI state (Python 1638 in early runs)
- **nvm has `Choco = $null` and `Winget = $null`** — choco nvm no-ops as SYSTEM, winget installs per-user; use nvm-noinstall.zip direct
- **WSL2 uses `wsl.exe --install`**, not Choco or winget
- **Claude Code installed via npm** to machine-wide prefix `C:\ProgramData\npm`
- **winget does NOT work as SYSTEM in NinjaOne** — stripped PATH; last resort only via Start-Job
- **reg.exe must use full path** `$env:SystemRoot\System32\reg.exe` in SYSTEM sessions — bare `reg` fails
- **Execution policy set to RemoteSigned** at install start — npm PS shims (claude.cmd, etc.) require it

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
- Run 6 (2026-04-20): **24m 43s — 12/12, 0 failures**; VS Code extensions confirmed, Claude installed; Claude public desktop shortcut missing
- Run 7 (2026-04-28): **NinjaOne Automation script** — `powershell-core` choco hung 52 min (user killed, exit -1); TEMP dir missing caused nvm + Node.js MSI + Python bundled EXE (1622) to fail; PowerShell 7 NOT FOUND (ghost Choco registration); 11/14 pass. Logs at `C:\projects\logs\`

## Session 9 changes (2026-04-28)
### Root causes diagnosed from Run 7 logs
1. **`powershell-core` Choco bulk install hung 52 min** — bulk install has no timeout; killed by user; Choco registered the package before MSI completed so per-package fallback saw "already latest" and marked OK, but pwsh.exe was never placed on disk
2. **`$env:TEMP` path didn't exist** — `C:\WINDOWS\system32\config\systemprofile\AppData\Local\Temp` not created on this machine; caused nvm download, Node.js MSI download, and Python bundled EXE (exit 1622 = msiexec can't write log) to fail
3. **No `VerifyExe` on PowerShell 7** — ghost Choco registration fooled the script into marking it installed

### Code changes committed this session
- `packages.config`: removed `powershell-core` (docker-desktop only remains)
- `Configure-UserEnvironment.ps1`: fixed bare `reg` → full path at lines 226, 260, 290 (hive load/add/unload)
- `Install-DevEnvironment.ps1`: fixed bare `reg` → full path at lines 938, 955 (Python 1638 offline profile cleanup); fixed WSL2 to also accept exit code 3010

## Session 10 changes (2026-04-28)
- **Replaced `Install-DevEnvironment.ps1`** with ChatGPT's improved rewrite (`C:\projects\logs\Install-DevEnvironment (1).ps1`)
  - Source file was 1510 lines; all three required additions were already present in (1): startup msg.exe, WSL 3010, SchemaVersion 1.1
  - nvm is now a **required** dependency (not optional); `Install-ClaudeCode` blocks if nvm/Node setup fails
  - Setup guide chatbot removed from this version (cleaner)
  - All three files parse clean (verified with PowerShell AST parser)

## Rollback fixes (session 7, 2026-04-20) — commit f1328f8
- Added `bundled` switch case: routes to `Invoke-RegistryUninstall`; Terraform force-removes directory
- Added `pre-existing` switch case: skips silently, not flagged as error
- Claude Desktop: `Remove-AppxProvisionedPackage` + `Remove-AppxPackage -AllUsers` in `direct` handler
- Fixed `DisplayName` StrictMode crash in `direct` registry fallback
- WSL2: `wsl.exe --uninstall` instead of failing winget call
- `reg.exe` full path (`$env:SystemRoot\System32\reg.exe`) throughout
- Added `Claude.lnk` to public desktop cleanup list

## Session 8 changes (2026-04-20)
- **Version stamp + staleness check** in Deploy and Rollback: `$ScriptVersion = 'GIT_COMMIT_HASH'` placeholder; fetches GitHub API at startup, compares 7-char SHA; unstamped = live pull (green); stamped+outdated = red + YES prompt
- **User notifications via `msg.exe`** added to all three scripts (deploy startup, rollback startup, install completion)
- **GIT_COMMIT_HASH placeholder bug fixed**: accidentally committed as literal SHA in `001a885`, causing live pulls to show OUTDATED. Restored in `6b81d18`.

## Known issues / open items
- **PowerShell 7 not installed on test machine** — ghost Choco entry from killed Run 7; new Install script's VerifyExe + hard verify will handle on next run
- **nvm not installed on test machine** — stable TempDir in new script fixes root cause; next run will install it as required
- **Claude Desktop rollback unverified**: MSIX removal not explicitly checked post-rollback
- **Python rollback**: no uninstall string in registry for machine-wide Python; fix: use bundled `ME_Python_3_12.exe /quiet /uninstall`
- **Claude Desktop shortcut**: not appearing on public desktop — requires new zip with Configure-UserEnvironment.ps1 changes
- WSL2 cannot be removed without a reboot
- libcurl DLL conflict (from Docker/AWS CLI) breaks git HTTPS — always use SSH for pushes
- KSM licensing needed for Keeper Commander re-enable

## Dev machine state (as of session 10, 2026-04-28)
- Keeper Commander installed on dev machine: `C:\Python314\Scripts\keeper.exe`
- SSH key pair: Windows ssh-agent service set to Automatic; PS profile loads key at login
- PS profile: `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- Keeper login works (Zscaler CA appended to `C:\Python314\Lib\site-packages\certifi\cacert.pem`)
- Keeper uses SSO — non-interactive access requires KSM (not licensed yet)

## Next steps (as of 2026-04-28 session 10)
1. **Rebuild zip** — run `Package-Release.ps1` + upload to GitHub release to pick up new Install-DevEnvironment.ps1
2. **Re-run deployment** on test machine — should now install PowerShell 7 (VerifyExe catches ghost) and nvm (stable TempDir)
3. Fix Python rollback: use bundled `ME_Python_3_12.exe /quiet /uninstall`
4. Verify Claude Desktop shortcut appears on public desktop after next zip rebuild
5. Request KSM licensing from Keeper admin
