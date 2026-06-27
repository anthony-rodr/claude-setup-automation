# AIE Claude Code Deployment Pipeline — Guide

## What This Is

An automated system that deploys developer environments (Claude Code, VS Code, Git, Node, Python, AWS CLI, etc.) to employee Windows machines via NinjaOne RMM. The deployment is triggered by an IT admin in NinjaOne and runs silently in the background as SYSTEM on the target machine.

---

## What Problem This Solves

### Before
- Deployment files were hosted on a public GitHub release — anyone with the URL could download them
- Pre-signed S3 URLs expired every 7 days and had to be manually updated in NinjaOne
- Pre-signed URLs contained `&` characters that NinjaOne's Script Variable UI would silently strip, breaking the download
- No integrity verification — if a file was tampered with, the installer would still run
- Only one person could build and release the package (required local AWS CLI setup)

### After
- S3 bucket is private — no public access
- A Lambda function generates fresh pre-signed URLs on demand — NinjaOne never needs updating
- SHA256 verification on every deployment — Bootstrap verifies Deploy.ps1 before running it, Deploy.ps1 verifies the zip before extracting it
- Any tech can trigger a release from the PSU dashboard — no local AWS setup required
- The entire build + upload process is one PSU job click

---

## Architecture Overview

```
Tech triggers PSU job
        │
        ▼
PSU (Docker, local machine)
  └─ Runs Build-And-Upload.ps1
       ├─ Builds claude-setup-automation.zip from bundled installers
       ├─ Computes ZipSHA256 + DeploySHA256 → writes to VERSIONS.md
       └─ Uploads 3 files to private S3:
            - Deploy-DevEnvironment.ps1
            - VERSIONS.md
            - claude-setup-automation.zip

NinjaOne triggers AIE-Claude-Deployment on target machine
        │
        ▼
NinjaOne-Bootstrap.ps1 (stored inline in NinjaOne)
  └─ Calls Lambda: aie-presign-url-claude-autodeployment
       ├─ Gets fresh pre-signed URL for VERSIONS.md → reads DeploySHA256
       ├─ Gets fresh pre-signed URL for Deploy-DevEnvironment.ps1
       │    └─ Verifies SHA256 before executing
       └─ Passes PackageUrl to Deploy-DevEnvironment.ps1
            └─ Deploy gets fresh pre-signed URL for zip
                 └─ Verifies ZipSHA256 before extracting
                      └─ Runs Install-DevEnvironment.ps1 as SYSTEM
```

---

## Components

| Component | Location | Purpose |
|---|---|---|
| `scripts/Package-Release.ps1` | Repo | Builds zip + computes SHA256 hashes |
| `psu/Build-And-Upload.ps1` | Repo (PSU reads from `/claude-setup-automation/`) | PSU job — build + S3 upload |
| `ninjaone/NinjaOne-Bootstrap.ps1` | NinjaOne (inline script) | Calls Lambda, verifies + runs Deploy |
| `scripts/Deploy-DevEnvironment.ps1` | S3 + Repo | Downloads + extracts zip, runs installer |
| `scripts/Install-DevEnvironment.ps1` | Inside zip | Installs all dev tools on target machine |
| `VERSIONS.md` | S3 + Repo | Contains ZipSHA256 + DeploySHA256 for integrity checks |
| Lambda: `aie-presign-url-claude-autodeployment` | AWS (us-east-2) | Generates pre-signed S3 URLs on demand |
| S3 bucket: `claude-deploy-scripts` | AWS (us-east-2) | Stores the 3 deployment files — private |

---

## AWS Resources

### S3 Bucket
- **Name:** `claude-deploy-scripts`
- **Region:** us-east-2
- **Access:** Private — public access blocked
- **Files:**
  - `Windows/Deploy-DevEnvironment.ps1`
  - `Windows/VERSIONS.md`
  - `Windows/claude-setup-automation.zip`

### IAM User
- **Name:** `anthony.sandbox`
- **Policy:** `aie-claude-deploy-s3-policy`
- **Permissions:** `s3:PutObject` + `s3:GetObject` scoped to `claude-deploy-scripts/Windows/*`
- **Purpose:** Used by PSU job to upload files to S3

### Lambda Function
- **Name:** `aie-presign-url-claude-autodeployment`
- **Region:** us-east-2
- **Runtime:** Python 3.x
- **Trigger:** Function URL (HTTPS, no IAM auth — protected by API key in header)
- **Role:** `aie-presign-url-claude-autodeployment-role` with `s3:GetObject` on the bucket
- **What it does:** Receives `?file=deploy|versions|package` + `x-api-key` header → returns a 7-day pre-signed S3 URL

### NinjaOne Script Variables
- **`lambdakey`** — API key for the Lambda function. Never changes, never expires.

---

## PSU Setup

PSU (PowerShell Universal) runs in Docker on the dev machine at `http://localhost:5000`.

### Docker Compose Location
`C:\projects\meow-it-agent-local\docker-compose.yml`

### Volume Mount
The claude-setup-automation project is mounted into the PSU container at `/claude-setup-automation`. This means PSU can read and write project files directly — no file copying needed.

### PSU Variables Required
Go to **Platform → Variables** in PSU:

| Variable Name | Type | Value |
|---|---|---|
| `aws_access_key_id` | String (not secret) | IAM access key ID |
| `aws_secret_access_key` | String (not secret) | IAM secret access key |

> **Note:** PSU's "Secret" vault type does not inject variables into script runspaces in PSU 4.5.x. Use plain String type. The values are still stored in PSU's encrypted database — they are not stored in any script or config file.

### PSU Script
Located at: `C:\projects\meow-it-agent-local\data\Repository\Scripts\claude-setup\Build-And-Upload.ps1`

This is the same file as `psu/Build-And-Upload.ps1` in the repo — PSU reads it directly from the mounted volume.

---

## How to Do a Release

When you update any scripts and want to push them to production:

1. Make your changes to scripts in `C:\projects\claude-setup-automation\scripts\`
2. Commit and push to GitHub
3. Open PSU at `http://localhost:5000`
4. Go to **Automation → Jobs → Build-And-Upload**
5. Click **Run**
6. Wait ~5 minutes for the build and upload to complete
7. Done — NinjaOne will automatically use the new files on the next deployment

You do **not** need to:
- Update NinjaOne Script Variables
- Generate or paste pre-signed URLs
- Run any commands manually
- Touch AWS at all

---

## How to Re-run a Deployment on a Machine

In NinjaOne, find the device and run the **AIE-Claude-Deployment** automation. The script is idempotent — tools that are already installed are skipped.

---

## Security Model

| Layer | How it's secured |
|---|---|
| S3 files | Private bucket — no public access |
| S3 access | Pre-signed URLs (7-day expiry, read-only) generated by Lambda |
| Lambda access | API key in `x-api-key` header (stored in NinjaOne as `lambdakey`) |
| Deploy.ps1 integrity | SHA256 verified by Bootstrap before execution |
| Zip integrity | SHA256 verified by Deploy.ps1 before extraction |
| OPSEC | No company name in scripts — uses "AIE" only |
| Credentials | Not stored in any script, git repo, or NinjaOne script body |

---

## How to Renew the Lambda API Key

If the API key is ever compromised:

1. Generate a new key: open PowerShell and run:
   ```powershell
   python -c "import secrets; print(secrets.token_hex(32))"
   ```
2. In the AWS Lambda console, update the `API_KEY` environment variable on `aie-presign-url-claude-autodeployment`
3. In NinjaOne, update the `lambdakey` Script Variable on AIE-Claude-Deployment
4. In PSU, no changes needed

---

## Troubleshooting

### Deployment fails on target machine — where are the logs?

On the target machine:
- `C:\ProgramData\AIE\Logs\ninja-deploy-<timestamp>.log` — Bootstrap log
- `C:\ProgramData\AIE\Logs\deploy-output-<timestamp>.log` — full installer output
- `C:\ProgramData\AIE\DevSetup\install.log` — detailed package install log

In NinjaOne, the Activity tab for the automation run shows a filtered live stream of the installer output.

### Bootstrap fails with "lambdakey script variable is not configured"

The `lambdakey` Script Variable is missing or blank on the AIE-Claude-Deployment automation in NinjaOne. Add it under Script Variables.

### Bootstrap fails with "DeploySHA256 not found in VERSIONS.md"

The VERSIONS.md on S3 is outdated. Run the PSU Build-And-Upload job to rebuild and re-upload.

### Bootstrap fails with "Deploy script integrity check FAILED"

The Deploy-DevEnvironment.ps1 on S3 does not match the hash in VERSIONS.md. Re-run the PSU job to rebuild everything consistently.

### PSU job fails with "aws_access_key_id PSU Variable is empty"

The PSU variable is not set or was created as "Secret" type (which doesn't inject in PSU 4.5.x). Go to **Platform → Variables**, delete and recreate it as plain String type with the correct value.

### PSU job uploads succeed but NinjaOne still uses old files

Check the VERSIONS.md on S3 was updated. The Deploy script compares VERSIONS.md to decide whether to re-download the zip. If the hash didn't change, it will skip the download.

### Lambda returns 401

The `x-api-key` header value doesn't match the `API_KEY` environment variable in the Lambda function. Verify the `lambdakey` NinjaOne variable matches the Lambda `API_KEY`.

### Lambda returns 400

The `file` query parameter is invalid. Valid values: `deploy`, `versions`, `package`.

---

## One-Time Setup Steps (Already Done — For Reference)

If this ever needs to be rebuilt from scratch:

### 1. S3 Bucket
1. Create bucket `claude-deploy-scripts` in us-east-2
2. Block all public access (Bucket settings → Block public access → enable all)

### 2. IAM User
1. Create user `anthony.sandbox` (or per-tech users)
2. Create policy `aie-claude-deploy-s3-policy`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": ["s3:PutObject", "s3:GetObject"],
       "Resource": "arn:aws:s3:::claude-deploy-scripts/Windows/*"
     }]
   }
   ```
3. Attach policy to user
4. Create access keys — save for `aws configure` and PSU Variables

### 3. Lambda Function
1. Create function `aie-presign-url-claude-autodeployment` (Python, us-east-2)
2. Execution role: create new with basic Lambda permissions + add inline policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::claude-deploy-scripts/Windows/*"
     }]
   }
   ```
3. Paste lambda_function.py code (see `ninjaone/` folder in repo for reference)
4. Add environment variable `API_KEY` = random hex string (`python -c "import secrets; print(secrets.token_hex(32))"`)
5. Deploy the function
6. Create Function URL (auth type: NONE — API key handled in code)
7. Copy the Function URL — hardcode it in `NinjaOne-Bootstrap.ps1`

### 4. PSU
1. Add volume mount to `docker-compose.yml`: `../claude-setup-automation:/claude-setup-automation`
2. Restart PSU container: `docker compose down && docker compose up -d`
3. Install AWS.Tools.S3 in container: `docker exec psu-local pwsh -Command "Install-Module -Name AWS.Tools.S3 -Force -Scope AllUsers"`
4. Add PSU Variables: `aws_access_key_id` and `aws_secret_access_key` (String type, not Secret)
5. Create script in PSU pointing at `/claude-setup-automation/psu/Build-And-Upload.ps1`

### 5. NinjaOne
1. Edit AIE-Claude-Deployment automation
2. Add Script Variable: `lambdakey` (String) = the Lambda API key
3. Replace the Bootstrap script body with the contents of `ninjaone/NinjaOne-Bootstrap.ps1`

---

## Claude CLI Prompt for Techs

If you need to work on this system with Claude CLI, paste the following at the start of your session:

---

```
I need your help with the AIE Claude Code deployment pipeline. Here is the full context:

WHAT THIS IS:
An automated system that deploys developer environments to Windows machines via NinjaOne RMM.
When an IT admin triggers the NinjaOne automation "AIE-Claude-Deployment", it runs silently
on the target machine as SYSTEM and installs: Claude Code, VS Code, Git, Node.js, Python,
AWS CLI, GitHub CLI, Terraform, and PowerShell 7.

REPO LOCATION: C:\projects\claude-setup-automation
PSU DOCKER: C:\projects\meow-it-agent-local\docker-compose.yml
PSU URL: http://localhost:5000

KEY FILES:
- scripts/Install-DevEnvironment.ps1 — installs all tools on the TARGET machine (runs as SYSTEM via NinjaOne)
- scripts/Deploy-DevEnvironment.ps1 — downloads and extracts the zip, runs the installer (runs as SYSTEM via NinjaOne)
- ninjaone/NinjaOne-Bootstrap.ps1 — stored inline in NinjaOne; calls Lambda for URLs, verifies SHA256, runs Deploy
- scripts/Package-Release.ps1 — builds the zip + computes SHA256 hashes + uploads to S3 (run via PSU job)
- psu/Build-And-Upload.ps1 — PSU job script; runs Package-Release.ps1 in a child process, uploads to S3
- VERSIONS.md — contains ZipSHA256 and DeploySHA256 for integrity verification

AWS RESOURCES:
- S3 bucket: claude-deploy-scripts (us-east-2, private)
- S3 files: Windows/Deploy-DevEnvironment.ps1, Windows/VERSIONS.md, Windows/claude-setup-automation.zip
- Lambda: aie-presign-url-claude-autodeployment (us-east-2)
  - Generates 7-day pre-signed S3 URLs on demand
  - Protected by API key in x-api-key header
  - NinjaOne stores the API key as Script Variable "lambdakey"
- IAM user: anthony.sandbox with aie-claude-deploy-s3-policy (PutObject + GetObject on bucket)

PSU SETUP:
- PSU 4.5.6 running in Docker Desktop (Ubuntu container)
- Project mounted at /claude-setup-automation in container
- AWS credentials stored as PSU Variables: aws_access_key_id, aws_secret_access_key (String type — NOT Secret type, which doesn't inject in PSU 4.5.x)
- PSU script file: C:\projects\meow-it-agent-local\data\Repository\Scripts\claude-setup\Build-And-Upload.ps1

DEPLOYMENT FLOW:
1. Tech triggers PSU job → builds zip, computes hashes, uploads 3 files to S3
2. NinjaOne admin runs AIE-Claude-Deployment on target machine
3. Bootstrap calls Lambda 3x to get pre-signed URLs → verifies Deploy.ps1 SHA256 → runs Deploy
4. Deploy verifies zip SHA256 → extracts → runs Install as SYSTEM

SECURITY NOTES:
- No credentials in any script or git repo
- S3 is private — only accessible via Lambda-generated pre-signed URLs
- SHA256 integrity chain: VERSIONS.md → Deploy.ps1 → zip → installer
- OPSEC: no company name in scripts, use "AIE" only
- Do NOT add NinjaOne API automation — intentional decision to avoid automated changes to NinjaOne
- Do NOT store credentials in NinjaOne Script Variables (pre-signed URLs are OK, static AWS keys are not)

KNOWN QUIRKS:
- PSU runspace doesn't load Compress-Archive, so Package-Release.ps1 runs in a child pwsh process
- PSU "Secret" variable type doesn't inject into scripts in 4.5.x — use plain String type
- NinjaOne strips & characters from Script Variable values — pre-signed URLs cannot be stored there (this is why Lambda was added)
- Scripts run on TARGET machines as SYSTEM — never confuse target machine with dev machine
- Logs on target machine: C:\ProgramData\AIE\Logs\

Please read CLAUDE.md in the repo first before making any changes: C:\projects\claude-setup-automation\CLAUDE.md
```

---

*Last updated: 2026-06-26*
