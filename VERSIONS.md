# Bundled Installer Versions

Built: 2026-06-25 21:16:20 UTC
Commit: 982a589
ZipSHA256: 4b9ee19275023f3be998a546301ab48883d177a876ee6700c2e70af5acf1d198
DeploySHA256: 99fa531bbb22708ccb85afceb627ff066636e11e42bc45fcf9f771164ce7979d

| Package | Version | File | Size |
|---------|---------|------|------|
| VS Code |  | ME_Visual_Studio_Code.exe | 149.7 MB |
| Git for Windows | v2.54.0.windows.1 | ME_Git_for_Windows.exe | 62.2 MB |
| AWS CLI v2 | latest | ME_AWS_CLI_v2.msi | 45.5 MB |
| Python 3.12 | 3.12.10-fallback | ME_Python_3_12.exe | 25.7 MB |
| GitHub CLI | v2.95.0 | ME_GitHub_CLI.msi | 14 MB |
| Terraform | 1.15.7 | ME_Terraform.zip | 33.7 MB |
| nvm-windows | 1.2.2 | ME_nvm_windows.zip | 6 MB |
| PowerShell 7 | v7.6.3 | ME_PowerShell_7.msi | 109.6 MB |
| Node.js LTS | v24.18.0 | ME_Node_LTS.zip | 34.8 MB |

**Not bundled** (downloaded at runtime by the installer):
- Docker Desktop  (~600 MB - Chocolatey + direct fallback)
- Claude Desktop  (MSIX - direct download)

Re-run Package-Release.ps1 before each deployment wave to refresh bundled versions.
