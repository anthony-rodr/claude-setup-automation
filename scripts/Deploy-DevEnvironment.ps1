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

$ScriptVersion = 'GIT_COMMIT_HASH'  # Stamped by Package-Release.ps1 — copy stamped script to NinjaOne

# ── Configuration ─────────────────────────────────────────────────────────────
# Stable URL — always points to the latest release asset named claude-setup-automation.zip.
# To deploy a new version: replace the asset on the GitHub release (keep the same filename).
# GitHub Releases:  https://github.com/anthony-rodr/claude-setup-automation/releases/latest/download/claude-setup-automation.zip
# Azure Blob (future): https://YOUR_ACCOUNT.blob.core.windows.net/YOUR_CONTAINER/claude-setup-automation.zip
$PackageUrl = 'https://github.com/anthony-rodr/claude-setup-automation/releases/latest/download/claude-setup-automation.zip'

# Where to stage the downloaded zip and extracted contents
$StageDir        = 'C:\ProgramData\MasterElectronics\Deploy'
$ZipPath         = Join-Path $StageDir 'setup.zip'
$ExtractDir      = Join-Path $StageDir 'package'
$VersionsUrl     = 'https://github.com/anthony-rodr/claude-setup-automation/releases/latest/download/VERSIONS.md'
$VersionsOnDisk  = Join-Path $StageDir 'VERSIONS.md'
# ──────────────────────────────────────────────────────────────────────────────

# Auth headers for private repo — PAT injected by bootstrap via $env:GITHUB_PAT
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

    # ── Startup banner + staleness check ──────────────────────────────────────
    Write-Host ('=' * 64)
    Write-Host '  Master Electronics — Developer Environment DEPLOY'
    Write-Host ('=' * 64)
    Write-Host "  Script version: $ScriptVersion" -NoNewline
    try {
        $verResp = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/anthony-rodr/claude-setup-automation/commits/main' `
            -Headers $AuthHeaders -ErrorAction Stop
        $latestSha = $verResp.sha.Substring(0, 7)
        if ($ScriptVersion -eq 'GIT_COMMIT_HASH') {
            # Pulled live from GitHub — always current, no stamp needed
            Write-Host "  [live — main @ $latestSha]" -ForegroundColor Green
        } elseif ($latestSha -eq $ScriptVersion) {
            Write-Host "  [$ScriptVersion — current]" -ForegroundColor Green
        } else {
            Write-Host "  [$ScriptVersion — OUTDATED, repo is $latestSha]" -ForegroundColor Red
            if ([System.Environment]::UserInteractive) {
                $ans = Read-Host "  This script is outdated. Were you intending to run this version? Type YES to continue"
                if ($ans -ne 'YES') { Write-Host 'Deployment cancelled.' -ForegroundColor Cyan; exit 0 }
            }
        }
    } catch {
        Write-Host '  [version check unavailable]' -ForegroundColor Yellow
    }
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

    # 1. Check if the bundle is already current by fetching VERSIONS.md (~2 KB)
    #    and comparing against the last deployed version on disk.
    $skipDownload = $false
    if (Test-Path $ExtractDir) {
        try {
            $resp = Invoke-WebRequest -Uri $VersionsUrl -Headers $AuthHeaders -UseBasicParsing -ErrorAction Stop
            # Content may be [byte[]] on older PS5 builds — decode explicitly
            $remoteVersions = if ($resp.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($resp.Content)
            } else {
                [string]$resp.Content
            }
            if (Test-Path $VersionsOnDisk) {
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
    }

    if (-not $skipDownload) {
        # 2. Remove stale extract, download and re-extract
        if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

        Write-Step "Downloading package from: $PackageUrl"
        Invoke-WebRequest -Uri $PackageUrl -Headers $AuthHeaders -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
        Write-Step "Download complete: $ZipPath"

        # 3. Extract
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
