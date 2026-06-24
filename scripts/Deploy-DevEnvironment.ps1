#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstrap script for NinjaOne deployment of the Master Electronics developer environment.

.DESCRIPTION
    Downloads the setup package from the configured URL, extracts it, and runs
    Install-DevEnvironment.ps1 as SYSTEM.  This is the only script that needs to
    be stored in NinjaOne — everything else comes from the zip.

    To update to a new version: upload the new zip to the release/blob location
    and update $PackageUrl below.  No changes to the NinjaOne script entry needed
    unless the URL structure changes.

.NOTES
    Runs as: SYSTEM (NinjaOne context)
    Tested:  Windows 11
#>
param(
    [string]$GithubPat   = '',
    [string]$PackageUrl  = '',
    [string]$VersionsUrl = ''
)

$ScriptVersion = 'abffb60'  # Stamped by Package-Release.ps1 — copy stamped script to NinjaOne

# ── Configuration ─────────────────────────────────────────────────────────────
# PackageUrl and VersionsUrl are passed as parameters from the NinjaOne Bootstrap
# (pre-signed S3 URLs stored as NinjaOne script parameters — not in code).
if (-not $PackageUrl)  { throw '-PackageUrl is required. Set it in the NinjaOne script parameters.' }
if (-not $VersionsUrl) { throw '-VersionsUrl is required. Set it in the NinjaOne script parameters.' }

# Where to stage the downloaded zip and extracted contents
$StageDir        = 'C:\ProgramData\AIE\Deploy'
$ZipPath         = Join-Path $StageDir 'setup.zip'
$ExtractDir      = Join-Path $StageDir 'package'
$VersionsOnDisk  = Join-Path $StageDir 'VERSIONS.md'
# ──────────────────────────────────────────────────────────────────────────────

# Auth headers — PAT from -GithubPat arg (explicit) or $env:GITHUB_PAT (inherited)
if ($GithubPat -and -not $env:GITHUB_PAT) { $env:GITHUB_PAT = $GithubPat }
$AuthHeaders = if ($env:GITHUB_PAT) {
    @{ Authorization = "token $env:GITHUB_PAT"; 'User-Agent' = 'claude-setup-automation' }
} else {
    @{ 'User-Agent' = 'claude-setup-automation' }
}

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
}

try {
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    # ── Startup banner ────────────────────────────────────────────────────────
    Write-Host ('=' * 64)
    Write-Host '  AIE — Developer Environment DEPLOY'
    Write-Host ('=' * 64)
    if ($ScriptVersion -eq 'GIT_COMMIT_HASH') {
        Write-Host "  Script version: [not stamped — run Package-Release.ps1]" -ForegroundColor Yellow
    } else {
        Write-Host "  Script version: $ScriptVersion" -ForegroundColor Green
    }
    Write-Host "  Computer: $env:COMPUTERNAME"
    Write-Host ('=' * 64)
    # ─────────────────────────────────────────────────────────────────────────

    # ── Notify signed-on users ────────────────────────────────────────────────
    Write-Step 'Notifying signed-on users…'
    try {
        $notifyMsg = 'IT Update: Developer tools are being deployed to this machine. This may take a while. Please save your work — a restart or sign-out may be required when complete.'
        & "$env:SystemRoot\System32\msg.exe" * /TIME:120 $notifyMsg 2>&1 | Out-Null
        Write-Step '  Notification sent to signed-on users.'
    } catch {
        Write-Step "  Could not send user notification (no active sessions or msg.exe unavailable): $_"
    }
    # ─────────────────────────────────────────────────────────────────────────

    # 1. Fetch VERSIONS.md to check staleness and get zip SHA256 for integrity check.
    #    Always fetched (even on first run) so SHA256 is available before downloading.
    $skipDownload    = $false
    $expectedZipHash = $null
    try {
        $resp = Invoke-WebRequest -Uri $VersionsUrl -Headers $AuthHeaders -UseBasicParsing -ErrorAction Stop
        # Content may be [byte[]] on older PS5 builds — decode explicitly
        $remoteVersions = if ($resp.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($resp.Content)
        } else {
            [string]$resp.Content
        }

        # Parse zip SHA256 for post-download integrity check
        if ($remoteVersions -match '(?m)^ZipSHA256:\s*([a-fA-F0-9]{64})') {
            $expectedZipHash = $Matches[1].ToLower()
            Write-Step "Zip SHA256 from VERSIONS.md: $($expectedZipHash.Substring(0,8))..."
        }

        # Check if current bundle is already up-to-date
        if ((Test-Path $ExtractDir) -and (Test-Path $VersionsOnDisk)) {
            $localVersions = Get-Content $VersionsOnDisk -Raw
            $installPresent = Get-ChildItem -Path $ExtractDir -Filter 'Install-DevEnvironment.ps1' -Recurse -ErrorAction SilentlyContinue |
                              Select-Object -First 1
            if ($installPresent -and $remoteVersions.Trim() -eq $localVersions.Trim()) {
                Write-Step "Bundle is current (VERSIONS.md matches) — skipping download."
                $skipDownload = $true
            } else {
                Write-Step "New version detected or extracted package incomplete — re-downloading bundle."
            }
        }
    } catch {
        Write-Step "Version check failed ($_) — proceeding with full download."
    }

    if (-not $skipDownload) {
        # 2. Remove stale extract, download and re-extract
        if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

        Write-Step "Downloading package..."
        Invoke-WebRequest -Uri $PackageUrl -Headers $AuthHeaders -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
        Write-Step "Download complete."

        # 3. Verify zip integrity before extracting
        if ($expectedZipHash) {
            Write-Step "Verifying zip integrity..."
            $actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedZipHash) {
                Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
                throw "ZIP integrity check FAILED — expected $expectedZipHash, got $actualHash — aborting to prevent tampered package execution."
            }
            Write-Step "ZIP integrity verified."
        } else {
            Write-Step "WARNING: No SHA256 found in VERSIONS.md — skipping integrity check."
        }

        # 4. Extract
        Write-Step "Extracting package…"
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
        Write-Step "Extraction complete."

        # Save VERSIONS.md so next run can compare
        $bundledVersions = Join-Path $ExtractDir 'bundled\VERSIONS.md'
        if (Test-Path $bundledVersions) {
            Copy-Item $bundledVersions $VersionsOnDisk -Force
        }
    }

    # 4. Locate install script (handles both flat and nested zip structures)
    $installScript = Get-ChildItem -Path $ExtractDir -Filter 'Install-DevEnvironment.ps1' -Recurse |
                     Select-Object -First 1
    if (-not $installScript) {
        throw "Install-DevEnvironment.ps1 not found in extracted package."
    }
    Write-Step "Found install script: $($installScript.FullName)"

    # Verify required files are present before handing off to the installer
    $scriptRoot = Split-Path $installScript.FullName -Parent
    $pkgRoot    = Split-Path $scriptRoot -Parent
    $required = @(
        'scripts\Install-DevEnvironment.ps1',
        'scripts\Configure-UserEnvironment.ps1',
        'bundled\ME_nvm_windows.zip',
        'bundled\ME_PowerShell_7.msi'
    )
    foreach ($rel in $required) {
        if (-not (Test-Path (Join-Path $pkgRoot $rel))) {
            throw "Required package file missing after extraction: $rel"
        }
    }
    Write-Step "Package integrity check passed."

    # 5. Run installer — spawn a new PowerShell process so execution policy and
    #    streams are controlled independently of the NinjaOne SYSTEM session.
    Write-Step "Starting installation…"
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File $installScript.FullName *>&1
    $exitCode = $LASTEXITCODE
    Write-Step "Installation script completed with exit code: $exitCode"
    exit $exitCode

} catch {
    Write-Host "[ERROR] Deployment failed: $_" -ForegroundColor Red
    exit 1
} finally {
    # Clean up zip (leave extracted folder in place — install script may still reference it)
    Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
}
