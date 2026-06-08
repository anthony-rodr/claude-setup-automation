# claude-setup-automation

Automated developer environment installer for Master Electronics. Deployed via **NinjaOne RMM** and runs on remote employee machines as **SYSTEM**.

---

## What it installs

| Tool | Method |
|------|--------|
| VS Code | Bundled |
| Git for Windows | Bundled |
| PowerShell 7 | Bundled |
| Python 3.12 | Bundled |
| nvm-windows | Bundled |
| Node.js LTS | Via nvm |
| GitHub CLI | Bundled |
| AWS CLI v2 | Bundled |
| Terraform | Bundled |
| Docker Desktop | Chocolatey + direct fallback |
| Claude Desktop | Direct MSIX download |
| Claude Code | Native binary from Anthropic CDN |
| WSL2 | `wsl.exe --install` |

All packages are skipped if already installed. Reruns are safe.

---

## Deployment architecture

```
NinjaOne (AIE-Claude-Deployment)
  └─ NinjaOne-Bootstrap.ps1  (stored inline in NinjaOne)
       └─ Deploy-DevEnvironment.ps1  (pulled fresh from GitHub raw each run)
            └─ claude-setup-automation.zip  (from GitHub release)
                 └─ Install-DevEnvironment.ps1
```

- **Bootstrap** — stored inline in NinjaOne. Downloads Deploy fresh from GitHub on every run. Only needs updating if bootstrap logic itself changes.
- **Deploy** — always pulled fresh from GitHub. Checks `VERSIONS.md` staleness before downloading the zip.
- **Install** — lives inside the zip. Updated by uploading a new zip to the GitHub release.

### NinjaOne automation names

| Platform | Automation name |
|----------|----------------|
| Windows  | AIE-Claude-Deployment |
| macOS    | AIE-CLAUDE-MacOS-Deployment |

---

## Releasing an update

```powershell
# 1. Make changes, commit, push
git add ...
git commit -m "..."
git push origin main

# 2. Build the zip (downloads bundled installers on first run; re-runs are fast)
.\scripts\Package-Release.ps1

# 3. Upload to GitHub release
gh release upload v1.0 claude-setup-automation.zip VERSIONS.md --clobber

# 4. Restore the stamped scripts (Package-Release stamps them with the git hash)
git checkout -- scripts/Deploy-DevEnvironment.ps1 scripts/Rollback-DevEnvironment.ps1
```

The next time NinjaOne runs the automation, Deploy detects the changed `VERSIONS.md` and downloads the new zip automatically.

> **Note:** Git HTTPS push is broken on the dev machine (libcurl DLL conflict from Docker/AWS CLI). Always use SSH.

### Updating the Bootstrap

The Bootstrap is pasted directly into NinjaOne and is not inside the zip. To update it:

1. Edit `ninjaone/NinjaOne-Bootstrap.ps1`, commit, push
2. Open **AIE-Claude-Deployment** in NinjaOne and replace the script body with the updated file contents

---

## Monitoring a deployment

Install progress streams live to NinjaOne Activity (updated every ~3 seconds).

To also watch the raw install log directly on the target machine:

```powershell
cat C:\ProgramData\MasterElectronics\DevSetup\install.log -Tail 50 -Wait
```

Log files written per run:

| File | Contents |
|------|---------|
| `C:\ProgramData\MasterElectronics\Logs\ninja-deploy-*.log` | Bootstrap events |
| `C:\ProgramData\MasterElectronics\Logs\deploy-output-*.log` | Full deploy + install stdout |
| `C:\ProgramData\MasterElectronics\Logs\deploy-error-*.log` | Stderr |
| `C:\ProgramData\MasterElectronics\DevSetup\install.log` | Structured install log (`[OK]`/`[WARN]`/`[FAIL]`) |
| `C:\ProgramData\MasterElectronics\verify-install.log` | Post-install verification summary |
| `C:\ProgramData\MasterElectronics\verify-configure.log` | User profile config summary |

---

## Rollback

```powershell
# Run as Administrator on the target machine
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Rollback-DevEnvironment.ps1
```

Reads the install manifest (`C:\ProgramData\MasterElectronics\DevSetup\manifest.json`) and uninstalls everything the installer recorded. WSL2 removal requires a reboot.

---

## Troubleshooting

**Script says installed but `claude --version` not found**
Machine PATH was updated during install. Open a new terminal, or run the binary directly:
```powershell
& "C:\ProgramData\Claude\bin\claude.exe" --version
```

**Zscaler TLS errors (npm, pip, AWS CLI)**
`Set-ZscalerCertEnv` writes a combined CA bundle to `C:\ProgramData\ZscalerCA\ca-bundle.pem` and sets `NODE_EXTRA_CA_CERTS`, `PIP_CERT`, `AWS_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` at machine scope. If these aren't set, check the install log for `[FAIL]` in the Zscaler section.

**WSL prompts for admin on rerun**
Fixed — the installer now checks registry keys (`LxssManager`, `VmCompute`) instead of running DISM, which requires admin even for read-only queries.

**NinjaOne shows "still processing" after install completes**
Check `C:\ProgramData\MasterElectronics\Logs\ninja-deploy-*.log` last line. If it says "Bootstrap exiting with code 0", the install succeeded and the delay is a NinjaOne UI timing issue, not a process hang.

---

## Repository layout

```
ninjaone/
  NinjaOne-Bootstrap.ps1        # pasted into NinjaOne (not in zip)
scripts/
  Deploy-DevEnvironment.ps1     # pulled fresh from GitHub by Bootstrap
  Install-DevEnvironment.ps1    # runs on target machine (inside zip)
  Configure-UserEnvironment.ps1 # per-user profile setup (inside zip)
  Rollback-DevEnvironment.ps1   # uninstaller
  Package-Release.ps1           # builds the zip on dev machine
  Test-DevEnvironment.ps1       # post-install health checks
bundled/                        # downloaded by Package-Release.ps1, shipped in zip
VERSIONS.md                     # version manifest checked by Deploy for staleness
CLAUDE.md                       # internal implementation notes
```
