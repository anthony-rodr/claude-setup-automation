<#
.SYNOPSIS
    Builds the claude-setup-automation.zip release package.

.DESCRIPTION
    Downloads the two installers that are slow or flaky over the network
    (Python 3.12 and VS Code) into the bundled/ directory, then zips the
    entire project — scripts/, chatbot/, bundled/ — as
    claude-setup-automation.zip in the project root.

    Upload the resulting zip as the asset on the GitHub Release.  The stable
    filename means NinjaOne's Deploy-DevEnvironment.ps1 always pulls the latest
    without a URL change.

.NOTES
    Run this from any PowerShell session — no elevation required.
    Requires internet access to download the bundled installers.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path $PSScriptRoot -Parent
$BundledDir  = Join-Path $ProjectRoot 'bundled'
$ZipPath     = Join-Path $ProjectRoot 'claude-setup-automation.zip'

function Write-Step {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" -ForegroundColor $Color
}

function Invoke-Fetch {
    param([string]$Url, [string]$Dest)
    Write-Step "  Downloading: $Url"
    # Remove partial file from any previous failed attempt
    if (Test-Path $Dest) { Remove-Item $Dest -Force }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
    $size = (Get-Item $Dest).Length / 1MB
    Write-Step ("  Saved: {0}  ({1:F1} MB)" -f $Dest, $size) 'Green'
}

# ── 1. Create bundled directory ───────────────────────────────────────────────
Write-Step 'Creating bundled/ directory…'
New-Item -ItemType Directory -Path $BundledDir -Force | Out-Null

# ── 2. Download Python 3.12 ───────────────────────────────────────────────────
Write-Step 'Resolving Python 3.12 installer URL…'
$pythonUrl = $null
try {
    $releases = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
    $rel      = $releases | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } |
                Select-Object -First 1
    $asset    = $rel.assets | Where-Object { $_.name -match 'amd64\.exe$' } | Select-Object -First 1
    if ($asset) { $pythonUrl = $asset.browser_download_url }
} catch {
    Write-Step "  GitHub API lookup failed: $_ — using fallback URL." 'Yellow'
}
if (-not $pythonUrl) {
    $pythonUrl = 'https://www.python.org/ftp/python/3.12.9/python-3.12.9-amd64.exe'
}
Write-Step "  Python URL: $pythonUrl"
Invoke-Fetch $pythonUrl (Join-Path $BundledDir 'ME_Python_3_12.exe')

# ── 3. Download VS Code ───────────────────────────────────────────────────────
Write-Step 'Downloading VS Code installer…'
Invoke-Fetch 'https://update.code.visualstudio.com/latest/win32-x64/stable' `
             (Join-Path $BundledDir 'ME_Visual_Studio_Code.exe')

# ── 4. Build zip ──────────────────────────────────────────────────────────────
Write-Step 'Building claude-setup-automation.zip…'
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

$include = @(
    (Join-Path $ProjectRoot 'scripts'),
    (Join-Path $ProjectRoot 'chatbot'),
    (Join-Path $ProjectRoot 'bundled')
) | Where-Object { Test-Path $_ }

Compress-Archive -Path $include -DestinationPath $ZipPath -CompressionLevel Optimal

$zipSize = (Get-Item $ZipPath).Length / 1MB
Write-Step ("Package ready: {0}  ({1:F1} MB)" -f $ZipPath, $zipSize) 'Green'
Write-Step 'Upload claude-setup-automation.zip as the asset on the GitHub Release.' 'Green'
