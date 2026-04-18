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
1. **Bulk Choco install** — `choco install scripts/packages.config` once before the per-package loop
2. **Per-package loop** with three tiers per package:
   - **Tier 0**: Bundled installer in `bundled/` — skips Choco entirely for that package
   - **Tier 1**: Chocolatey
   - **Tier 2**: Direct download
   - **Tier 3**: winget (last resort — unreliable as SYSTEM)
3. **Parallel profile config** — all existing user profiles configured simultaneously via Start-Job

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

**Not bundled** (too large or Choco handles reliably):
- Docker Desktop (~600 MB) — Choco
- PowerShell 7 (~100 MB) — Choco

## packages.config (Choco bulk list)
Lists all 7 Choco-installable packages: git, vscode, powershell-core, gh, docker-desktop, awscli, terraform.
Stays comprehensive — Tier 0 handles bundled ones before Choco gets a chance in the per-package loop.

## Key design decisions
- **Python has `Choco = $null`** — choco python312 exits 1638 when registry remnants exist
- **Tier 0 exists** because Choco running before bundled installers leaves conflicting MSI state (caused Python 1638 failures during testing)
- **nvm has `Choco = $null` and `Winget = $null`** — choco nvm no-ops as SYSTEM, winget installs per-user; use nvm-noinstall.zip direct
- **WSL2 uses `wsl.exe --install`**, not Choco or winget
- **Claude Code installed via npm** to machine-wide prefix `C:\ProgramData\npm`

## Known issues
- AWS CLI choco uninstall times out in rollback — force cleanup handles it
- WSL2 cannot be removed without a reboot
- Rollback verification is PATH-only — can miss off-PATH installs
- libcurl DLL conflict (from Docker/AWS CLI) breaks git HTTPS — always use SSH for pushes
