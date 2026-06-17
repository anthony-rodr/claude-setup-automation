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
| Claude Desktop | Direct MSIX download |
| Claude Code | Native binary from Anthropic CDN |

All packages are skipped if already installed. Reruns are safe.

---

## How it works

```
NinjaOne (AIE-Claude-Deployment)
  └─ NinjaOne-Bootstrap.ps1  (stored inline in NinjaOne)
       └─ Deploy-DevEnvironment.ps1  (pulled from S3 each run)
            └─ claude-setup-automation.zip  (from S3)
                 └─ Install-DevEnvironment.ps1
```

- **Bootstrap** — stored inline in NinjaOne. Downloads the deploy script fresh from S3 on every run.
- **Deploy** — always pulled fresh. Checks `VERSIONS.md` staleness before downloading the zip.
- **Install** — lives inside the zip. Installs all tools, configures user profiles, and writes a manifest and logs to `C:\ProgramData\MasterElectronics\`.

---

## Repository layout

```
ninjaone/
  NinjaOne-Bootstrap.ps1        # stored inline in NinjaOne (not in zip)
  Repair-ClaudeCode.ps1         # stored inline in NinjaOne (AIE-Claude-Code-Repair)
scripts/
  Deploy-DevEnvironment.ps1     # downloaded fresh by Bootstrap each run
  Install-DevEnvironment.ps1    # runs on target machine (inside zip)
  Configure-UserEnvironment.ps1 # per-user profile setup (inside zip)
  Rollback-DevEnvironment.ps1   # uninstalls everything recorded in the manifest
  Package-Release.ps1           # builds the release zip
  Test-DevEnvironment.ps1       # post-install health checks
bundled/                        # installers shipped inside the zip
VERSIONS.md                     # version manifest; Deploy uses this to detect updates
```
