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
$StageDir   = 'C:\ProgramData\MasterElectronics\Deploy'
$ZipPath    = Join-Path $StageDir 'setup.zip'
$ExtractDir = Join-Path $StageDir 'package'
# ──────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
}

try {
    # 1. Create staging directory
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StageDir   -Force | Out-Null
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

    # 2. Download package
    Write-Step "Downloading package from: $PackageUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest -Uri $PackageUrl -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
    Write-Step "Download complete: $ZipPath"

    # 3. Extract
    Write-Step "Extracting package…"
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force
    Write-Step "Extraction complete."

    # 4. Locate install script (handles both flat and nested zip structures)
    $installScript = Get-ChildItem -Path $ExtractDir -Filter 'Install-DevEnvironment.ps1' -Recurse |
                     Select-Object -First 1
    if (-not $installScript) {
        throw "Install-DevEnvironment.ps1 not found in extracted package."
    }
    Write-Step "Found install script: $($installScript.FullName)"

    # 5. Run installer
    Write-Step "Starting installation…"
    & $installScript.FullName -Force
    Write-Step "Installation script completed with exit code: $LASTEXITCODE"
    exit $LASTEXITCODE

} catch {
    Write-Host "[ERROR] Deployment failed: $_" -ForegroundColor Red
    exit 1
} finally {
    # Clean up zip (leave extracted folder in place — install script may still reference it)
    Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
}
