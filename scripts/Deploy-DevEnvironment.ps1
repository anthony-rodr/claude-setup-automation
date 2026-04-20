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

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
}

try {
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    # 1. Check if the bundle is already current by fetching VERSIONS.md (~2 KB)
    #    and comparing against the last deployed version on disk.
    $skipDownload = $false
    if (Test-Path $ExtractDir) {
        try {
            $resp = Invoke-WebRequest -Uri $VersionsUrl -UseBasicParsing -ErrorAction Stop
            # Content may be [byte[]] on older PS5 builds — decode explicitly
            $remoteVersions = if ($resp.Content -is [byte[]]) {
                [System.Text.Encoding]::UTF8.GetString($resp.Content)
            } else {
                [string]$resp.Content
            }
            if (Test-Path $VersionsOnDisk) {
                $localVersions = Get-Content $VersionsOnDisk -Raw
                if ($remoteVersions.Trim() -eq $localVersions.Trim()) {
                    Write-Step "Bundle is current (VERSIONS.md matches) — skipping download."
                    $skipDownload = $true
                } else {
                    Write-Step "New version detected — re-downloading bundle."
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
        Invoke-WebRequest -Uri $PackageUrl -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
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

    # 5. Run installer
    Write-Step "Starting installation…"
    & $installScript.FullName
    Write-Step "Installation script completed with exit code: $LASTEXITCODE"
    exit $LASTEXITCODE

} catch {
    Write-Host "[ERROR] Deployment failed: $_" -ForegroundColor Red
    exit 1
} finally {
    # Clean up zip (leave extracted folder in place — install script may still reference it)
    Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
}
