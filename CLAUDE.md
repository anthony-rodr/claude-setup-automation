# Claude Code — Project Context

## What this project is
Automated developer environment installer for Master Electronics.
Scripts are deployed via **NinjaOne RMM** and run on **remote employee machines as SYSTEM**.
This is NOT run on the dev machine. Never confuse the two.

## Machines involved
- **Dev machine** (adm_arodriguez, C:\projects\claude-setup-automation): primary dev machine; SSH key at `C:\Users\adm_arodriguez\.ssh\id_ed25519`; HTTPS push broken (libcurl DLL conflict from Docker/AWS CLI) — use SSH only
- **Second machine** (zombi, C:\repo\claude-setup-automation): also used for development; SSH key at `C:\Users\zombi\.ssh\id_ed25519` added to anthony-rodr GitHub account; push via SSH to `git@github.com:anthony-rodr/claude-setup-automation.git`
- **Test/target machines**: separate remote computers where the installer actually runs as SYSTEM via NinjaOne

## Deployment architecture (3 tiers)

```
NinjaOne bootstrap script (stored in NinjaOne)
  └── downloads Deploy-DevEnvironment.ps1 from GitHub → executes it → streams logs to NinjaOne

Deploy-DevEnvironment.ps1 (in GitHub repo, downloaded fresh each run)
  └── downloads claude-setup-automation.zip from GitHub release → extracts → runs Install-DevEnvironment.ps1

Install-DevEnvironment.ps1 (inside the zip)
  └── installs all tools, configures users, writes manifest/logs
```

- **NinjaOne bootstrap** — small launcher script stored in NinjaOne. Pulls the latest `Deploy-DevEnvironment.ps1` from GitHub on every run. Never needs manual updating unless the bootstrap logic itself changes.
- **Deploy-DevEnvironment.ps1** — always pulled fresh from GitHub by the bootstrap. Detects new zip via VERSIONS.md staleness check before downloading.
- **Install-DevEnvironment.ps1** — lives inside the zip. Updated by uploading a new zip to the GitHub release.

## Deployment workflow
1. Make changes to scripts, commit, push to GitHub
2. Run `scripts/Package-Release.ps1` — downloads bundled installers into `bundled/`, runs syntax check, builds `claude-setup-automation.zip`
   - Re-runs are fast: already-present files in `bundled/` are skipped (delete a file to force refresh)
   - Fails if any of the 8 required bundle files are missing
   - Stamps `Deploy-DevEnvironment.ps1` and `Rollback-DevEnvironment.ps1` in-place with git hash (informational only — restore after: `git checkout -- scripts/Deploy-DevEnvironment.ps1 scripts/Rollback-DevEnvironment.ps1`)
3. Upload zip + VERSIONS.md to GitHub release:
   - `gh release upload v1.0 claude-setup-automation.zip VERSIONS.md --clobber`
4. Run the NinjaOne automation on target machines — bootstrap pulls latest Deploy from GitHub, Deploy detects new VERSIONS.md and downloads new zip, Install runs

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
6. **Completion `msg.exe` notification** via `Send-UserNotification` (startup notification is in Deploy, not Install)

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
| `ME_nvm_windows.zip` | nvm-windows (added session 10 — required dependency) |
| `ME_PowerShell_7.msi` | PowerShell 7 (added session 10 — Choco hung 52 min in Run 7) |

**Not bundled** (downloaded at runtime by the installer):
- Docker Desktop (~600 MB) — Choco + direct fallback
- Claude Desktop — MSIX direct download

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
| PowerShell 7 | `VerifyCmd = 'pwsh'`, `VerifyExe = 'C:\Program Files\PowerShell\7\pwsh.exe'` |
| nvm | `VerifyCmd = 'nvm'`, `VerifyExe = 'C:\ProgramData\nvm\nvm.exe'` |
| Python 3.12 | `VerifyCmd = 'python'` |
| GitHub CLI | `VerifyCmd = 'gh'` |
| Docker Desktop | `VerifyCmd = 'docker'` — reinstall resets settings |
| AWS CLI v2 | `VerifyCmd = 'aws'` |
| Terraform | `VerifyCmd = 'terraform'` |
| Claude Desktop | `VerifyAppx = '*Claude*'` — checks provisioned MSIX |

## Package notes
- **Keeper Commander** — **disabled 2026-04-20** (not in Install-DevEnvironment.ps1)
  - pip install fails consistently: Zscaler blocks pypi.org at network level even after CA cert injection
  - Do NOT re-enable until KSM is licensed and a non-pip delivery method is available
- **Claude Desktop** — `DType = 'msix'`, uses `Add-AppxProvisionedPackage` (machine-wide)
  - `VerifyAppx = '*Claude*'` skips if already provisioned
  - Public desktop shortcut created by `Configure-UserEnvironment.ps1` via `Get-AppxPackage -AllUsers`
- **PowerShell 7** — now bundled as `ME_PowerShell_7.msi`; Choco still used as fallback if bundled fails
  - `VerifyExe = 'C:\Program Files\PowerShell\7\pwsh.exe'` catches ghost Choco registrations
- **nvm-windows** — now bundled as `ME_nvm_windows.zip`; required dependency for Node/Claude Code stack

## Configure-UserEnvironment.ps1 — what it does (machine-wide model)
Runs per-user profile (as SYSTEM during install, as that user at logon via scheduled task).
Does **not** create per-user npm prefixes — npm global is machine-wide at `C:\ProgramData\npm`.

Current responsibilities:
1. **Claude settings** — writes `~/.claude/settings.json` with `preferredShell = Git Bash path`
2. **User PATH** — ensures `NVM_HOME`, `NVM_SYMLINK`, `C:\ProgramData\npm` are in user PATH registry key (safety net; machine PATH already has them)
3. **Desktop shortcuts** — VS Code, Git Bash (per-user); Claude (public desktop via AppX)
4. **VS Code extensions** — installed via `--user-data-dir` when running as SYSTEM; normally via logon task
5. **Marker file** — writes `~/.claude/.devsetup-configured` so logon task skips on subsequent logins

Removed in session 10 (were wrong for machine-wide model):
- `Set-NpmPrefix` — was writing per-user `~\AppData\Roaming\npm` to `.npmrc`
- `Set-PowerShellProfile` — was injecting per-user PS profile snippet pointing at wrong npm path
- `New-ChatbotShortcut` — chatbot removed from project

## Key design decisions
- **No bulk Choco at all** — per-package `Invoke-Process` with 900s timeout; `powershell-core` hung 52 min in Run 7 under bulk call
- **`$TempDir` = stable ProgramData path** — SYSTEM's `AppData\Local\Temp` may not exist on newly provisioned machines
- **Bundled nvm + PS7** — both are required; Choco caused problems (nvm no-ops as SYSTEM, PS7 hung); bundle guarantees install
- **nvm has `Choco = $null` and `Winget = $null`** — choco nvm no-ops as SYSTEM, winget installs per-user; use nvm-noinstall.zip direct
- **WSL2 uses `wsl.exe --install`**, not Choco or winget
- **Claude Code installed via npm** to machine-wide prefix `C:\ProgramData\npm`
- **winget does NOT work as SYSTEM in NinjaOne** — stripped PATH; last resort only via Start-Job
- **reg.exe must use full path** `$env:SystemRoot\System32\reg.exe` in SYSTEM sessions — bare `reg` fails
- **Execution policy set to RemoteSigned** at install start — npm PS shims (claude.cmd, etc.) require it
- **Deploy startup notification only** — Install removed its startup `Send-UserNotification`; Deploy fires earlier (before zip download)

## Bundle version check
Deploy-DevEnvironment.ps1 fetches `VERSIONS.md` (~2 KB) from the release before downloading
the full zip. Skips download if VERSIONS.md matches AND `Install-DevEnvironment.ps1` is present.
`VERSIONS.md` now includes the git commit hash (added session 10) so any script-only change
(without bundle version changes) still triggers a re-download.

After extraction, Deploy verifies required files are present before launching the installer:
`scripts\Install-DevEnvironment.ps1`, `scripts\Configure-UserEnvironment.ps1`,
`bundled\ME_nvm_windows.zip`, `bundled\ME_PowerShell_7.msi`

## Run history
- Run 1 (2026-04-18): 19m 22s — 12/12, bulk Choco slow (bundled pkgs in packages.config — fixed)
- Run 2 (2026-04-18): ~13m — 11/12, Python failed (bootstrapper exits fast before child msiexec completes)
- Run 3 (2026-04-18): 17m 56s — 11/14, Python same failure, Claude Desktop per-user not provisioned
- Run 4 (2026-04-20): Python 3.12 INSTALLED, pip hung on Keeper (Zscaler blocked pypi.org)
- Run 5 (2026-04-20): pip still failed — CA cert injection works but Zscaler blocks at network level; Keeper disabled
- Run 6 (2026-04-20): **24m 43s — 12/12, 0 failures**; VS Code extensions confirmed, Claude installed; Claude public desktop shortcut missing
- Run 7 (2026-04-28): **NinjaOne Automation script** — `powershell-core` choco hung 52 min (user killed, exit -1); TEMP dir missing caused nvm + Node.js MSI + Python bundled EXE (1622) to fail; PowerShell 7 NOT FOUND (ghost Choco registration); 11/14 pass. Logs at `C:\projects\logs\`
- Run 11 (2026-04-29): **11/12** — Python NOT FOUND; root cause: bundled EXE returned null exit code (PS 5.1 bug), fell through to Choco which hit 1603 because bundled EXE had already registered the MSI product code
- Run 12 (2026-04-29): **11/12** — Python NOT FOUND again (same root cause); VS Code extensions confirmed working
- Run 13 (2026-04-29): in progress — null exit code fix deployed (commit ec71501)

## Session 9 changes (2026-04-28)
### Root causes diagnosed from Run 7 logs
1. **`powershell-core` Choco bulk install hung 52 min** — bulk install has no timeout; Choco registered before MSI completed → ghost registration
2. **`$env:TEMP` path didn't exist** — caused nvm download, Node.js MSI, Python bundled EXE (exit 1622) to fail
3. **No `VerifyExe` on PowerShell 7** — ghost Choco registration fooled script into marking it installed

### Code changes committed this session
- `packages.config`: removed `powershell-core`
- `Configure-UserEnvironment.ps1`: fixed bare `reg` → full path (3 places)
- `Install-DevEnvironment.ps1`: fixed bare `reg` → full path (2 places); WSL2 accepts exit 3010

## Session 10 changes (2026-04-28)
### Install-DevEnvironment.ps1
- Replaced with ChatGPT rewrite (`C:\projects\logs\Install-DevEnvironment (1).ps1`) — 1510 lines
- Stable TempDir, Invoke-Process timeouts, VerifyExe hard verify, nvm required, startup+completion notifications
- Removed startup `Send-UserNotification` (Deploy fires earlier)

### Configure-UserEnvironment.ps1
- Removed `Set-NpmPrefix`, `Set-PowerShellProfile`, `New-ChatbotShortcut` (wrong for machine-wide model)
- `Set-UserPath` now adds machine-wide paths only: `NVM_HOME`, `NVM_SYMLINK`, `C:\ProgramData\npm`
- Fixed VS Code shortcut: `$UserProfile\AppData\Local` instead of `$env:LOCALAPPDATA` (SYSTEM bug)
- Verification report: removed stale npm/PS-profile checks; checks machine PATH for `C:\ProgramData\npm`

### Package-Release.ps1
- Added `ME_nvm_windows.zip` (nvm-windows, required) and `ME_PowerShell_7.msi` (PS7, required) bundles
- Added required-bundles gate: throws before zip if any of 8 required files are missing
- Removed `chatbot/` from zip include list (chatbot removed from project)
- VERSIONS.md now includes git commit hash — Deploy detects script-only changes and re-downloads

### Deploy-DevEnvironment.ps1
- Notification message: removed "15-30 minutes" time estimate
- Post-extraction integrity check: verifies 4 required files present before launching installer
- Installer invocation: `powershell.exe -ExecutionPolicy Bypass -NoProfile -File ... *>&1` (safer for NinjaOne)

### Rollback-DevEnvironment.ps1
- Fixed `bundled` case: added nvm-windows directory removal + NVM_HOME/NVM_SYMLINK env + PATH cleanup
  (installer now records nvm as `bundled`, not `direct`)
- Fixed `bundled` case: Terraform and nvm-windows as named branches; other bundled → registry uninstall
- Remaining cleanup completed session 11: removed 'Developer Setup Guide' from shortcut lists,
  added unconditional `C:\ProgramData\npm\claude*` removal, commented legacy .npmrc/AppData\Roaming\npm
  and ANTHROPIC_API_KEY sections

## Rollback fixes (session 7, 2026-04-20) — commit f1328f8
- Added `bundled` switch case: routes to `Invoke-RegistryUninstall`; Terraform force-removes directory
- Added `pre-existing` switch case: skips silently, not flagged as error
- Claude Desktop: `Remove-AppxProvisionedPackage` + `Remove-AppxPackage -AllUsers` in `direct` handler
- WSL2: `wsl.exe --uninstall` instead of failing winget call
- `reg.exe` full path throughout; `Claude.lnk` added to public desktop cleanup list

## Session 8 changes (2026-04-20)
- **Version stamp + staleness check** in Deploy and Rollback: `$ScriptVersion = 'GIT_COMMIT_HASH'` placeholder
- **User notifications via `msg.exe`** added to all three scripts
- **GIT_COMMIT_HASH placeholder bug fixed**: accidentally committed as literal SHA in `001a885`

## Session 11 changes (2026-04-29)
- **Bootstrap mutex guard** — `Global\MasterElectronics-DevEnvironment-Install` prevents concurrent installs; second instance logs "already running" and exits 0
- **Bootstrap refactored** — single try/catch/finally; `$finalExitCode` variable; `exit` only at end (commit fe974ae)
- **Tier-2 duplicate retry fix** — direct-download tier now guards `-not (Test-Path (Get-BundledPath $Pkg))` so it doesn't retry the bundled file that already failed

## Session 12 changes (2026-04-29)
### Root cause of Python 1603 (diagnosed)
`Invoke-Process` returns `$null` for `$p.ExitCode` on PS 5.1 for launcher-style EXEs (Python, Git, VS Code bundled installers). `$null -notin @(0,3010)` = `$true` in PowerShell → every bundled EXE was treated as failure. Python's bundled EXE actually installed successfully (~50s runtime) and registered its MSI product code. Choco then found "same version already installed" → 1603.

### Code changes (commit 8cedf92 + ec71501)
- **`Invoke-Process` null exit code fix** — `if ($null -eq $exitCode) { $exitCode = 0 }` + WARN log; same pattern as Bootstrap (commit ec71501)
- **Python `PreInstall` hook** — clears stale `C:\Python312` / `C:\Program Files\Python312` dirs before install attempt (directory cleanup only — not MSI product DB, per ChatGPT review)
- **`PreInstall` hook mechanism** — generic `PreInstall` scriptblock in package catalog; called in `Install-Package` after pre-checks, before install tiers
- **AWS CLI v2 rollback pattern** — registry DisplayName is `"AWS Command Line Interface v2"`, not `"AWS CLI v2"`; fixed in both `bundled` and `choco` fallback paths of Rollback script (commit 8cedf92)
- **MSI exit code 1641** — added to accepted codes alongside 0 and 3010 (reboot initiated by installer)

### Expected behavior after fix
Bundled EXEs will log `[WARN] Invoke-Process: null exit code — treating as 0` then `[OK] Direct install OK` instead of falling through to Choco. Python's AltPaths loop adds `C:\Program Files\Python312` to machine PATH.

## Known issues / open items
- **NinjaOne bootstrap "still processing"** — automation completes and install log shows success, but NinjaOne UI doesn't mark it done; root cause unknown (process tree inheritance? console handle?); need diagnostic: check ninja-deploy-*.log last line on test machine
- **Claude Desktop rollback unverified**: MSIX removal not explicitly checked post-rollback
- **Python rollback** (lower priority): bundled `ME_Python_3_12.exe /quiet /uninstall` would be cleaner than registry uninstall
- WSL2 cannot be removed without a reboot
- libcurl DLL conflict (from Docker/AWS CLI) breaks git HTTPS — always use SSH for pushes
- KSM licensing needed for Keeper Commander re-enable

## Dev machine state (as of session 10, 2026-04-28)
- Keeper Commander installed on dev machine: `C:\Python314\Scripts\keeper.exe`
- SSH key pair: Windows ssh-agent service set to Automatic; PS profile loads key at login
- PS profile: `~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
- Keeper login works (Zscaler CA appended to `C:\Python314\Lib\site-packages\certifi\cacert.pem`)
- Keeper uses SSO — non-interactive access requires KSM (not licensed yet)

## Next steps (as of 2026-04-29 session 12)
1. **Run 13** — rollback + reboot + deploy; look for `[WARN] Invoke-Process: null exit code` + `[OK] Direct install OK: Python 3.12`
2. **Diagnose NinjaOne "still processing"** — check `C:\ProgramData\MasterElectronics\Logs\ninja-deploy-*.log` last line; if "Bootstrap exiting with code X" is present, issue is NinjaOne UI/timing not process hang
3. **Update CLAUDE.md** with Run 13 results
4. Fix Python rollback: use bundled `ME_Python_3_12.exe /quiet /uninstall`
5. Request KSM licensing from Keeper admin
