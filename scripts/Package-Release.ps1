#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the claude-setup-automation.zip release package.

.DESCRIPTION
    Downloads the latest version of each bundled installer into bundled/, then
    zips scripts/ and bundled/ as claude-setup-automation.zip in the project root.

    Bundled installers let Install-DevEnvironment.ps1 deploy with minimal network
    activity on target machines.  Each URL is resolved dynamically so the zip
    always ships the latest stable release at build time.

    Bundled packages (in order, largest last):
      VS Code          — always-latest redirect from Microsoft CDN
      Git for Windows  — latest release from GitHub API
      AWS CLI v2       — always-latest MSI from Amazon CDN
      Python 3.12      — latest 3.12.x from GitHub API / python.org fallback
      GitHub CLI       — latest release from GitHub API
      Terraform        — latest release from HashiCorp checkpoint API
      nvm-windows      — latest nvm-noinstall.zip from GitHub API (required)
      PowerShell 7     — latest win-x64 MSI from GitHub API (required)

    NOT bundled (downloaded at runtime by the installer):
      Docker Desktop  — ~600 MB; Chocolatey + direct fallback at install time
      Claude Desktop  — MSIX downloaded directly at install time

    A VERSIONS.md manifest is written to bundled/ so IT can see exactly what
    versions are in the zip and when it was built.  Re-run this script before
    each deployment wave to keep the bundle current.

.NOTES
    Run from any PowerShell session — no elevation required.
    Requires internet access to download the bundled installers.
    Upload the resulting zip as the asset on the v1.0 GitHub Release.
    The stable filename means NinjaOne never needs a URL change.
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
    param([string]$Url, [string]$Dest, [switch]$Force)
    if ((Test-Path $Dest) -and -not $Force) {
        $size = (Get-Item $Dest).Length / 1MB
        Write-Step ('  Already present — skipping: {0}  ({1:F1} MB)' -f (Split-Path $Dest -Leaf), $size) 'DarkGreen'
        return $size
    }
    Write-Step "  Downloading: $Url"
    if (Test-Path $Dest) { Remove-Item $Dest -Force }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    # Run download in a background job so we can poll file size for live progress
    $job = Start-Job -ScriptBlock {
        param($url, $dest)
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    } -ArgumentList $Url, $Dest

    while ($job.State -eq 'Running') {
        $label = if (Test-Path $Dest) { '{0:F1} MB downloaded' -f ((Get-Item $Dest).Length / 1MB) } `
                 else { 'connecting...' }
        Write-Host ("`r    $label" + (' ' * 10)) -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 500
    }
    Write-Host ''

    if ($job.State -ne 'Completed') {
        $reason = $job.ChildJobs[0].JobStateInfo.Reason
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "Download failed: $reason"
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $Dest)) { throw "Download produced no file: $Url" }
    $size = (Get-Item $Dest).Length / 1MB
    Write-Step ('  Saved: {0}  ({1:F1} MB)' -f (Split-Path $Dest -Leaf), $size) 'Green'
    return $size
}

function Resolve-GitHubLatest {
    param([string]$Repo, [string]$AssetPattern)
    $r = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $r.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) { throw "No asset matching '$AssetPattern' in $Repo latest release" }
    return [pscustomobject]@{ Url = $asset.browser_download_url; Version = $r.tag_name; Name = $asset.name }
}

# ── 1. Create bundled directory ───────────────────────────────────────────────
Write-Step 'Creating bundled/ directory…'
New-Item -ItemType Directory -Path $BundledDir -Force | Out-Null

$manifest = [System.Collections.Generic.List[pscustomobject]]::new()
$buildDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

# ── 2. VS Code (always-latest redirect, no version in URL) ────────────────────
Write-Step 'Resolving VS Code installer…'
$vscodeDest = Join-Path $BundledDir 'ME_Visual_Studio_Code.exe'
$sz = Invoke-Fetch 'https://update.code.visualstudio.com/latest/win32-x64/stable' $vscodeDest
$vscodeVer = try { (Get-Item $vscodeDest).VersionInfo.ProductVersion } catch { 'latest' }
$manifest.Add([pscustomobject]@{ Package='VS Code'; Version=$vscodeVer; File='ME_Visual_Studio_Code.exe'; SizeMB=[math]::Round($sz,1) })

# ── 3. Git for Windows ────────────────────────────────────────────────────────
Write-Step 'Resolving Git for Windows installer…'
try {
    $git = Resolve-GitHubLatest 'git-for-windows/git' '-64-bit\.exe$'
    Write-Step "  Git version: $($git.Version)  ($($git.Name))"
    $sz = Invoke-Fetch $git.Url (Join-Path $BundledDir 'ME_Git_for_Windows.exe')
    $manifest.Add([pscustomobject]@{ Package='Git for Windows'; Version=$git.Version; File='ME_Git_for_Windows.exe'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: Git download failed: $_ - skipping." 'Yellow'
}

# ── 4. AWS CLI v2 (Amazon provides a stable always-latest URL) ────────────────
Write-Step 'Downloading AWS CLI v2 (always-latest MSI)…'
try {
    $sz = Invoke-Fetch 'https://awscli.amazonaws.com/AWSCLIV2.msi' (Join-Path $BundledDir 'ME_AWS_CLI_v2.msi')
    $manifest.Add([pscustomobject]@{ Package='AWS CLI v2'; Version='latest'; File='ME_AWS_CLI_v2.msi'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: AWS CLI download failed: $_ - skipping." 'Yellow'
}

# ── 5. Python 3.12 ───────────────────────────────────────────────────────────
Write-Step 'Resolving Python 3.12 installer…'
$pythonUrl = $null
$pythonVer = '3.12.x'
try {
    $releases = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
    $rel = $releases | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } |
           Select-Object -First 1
    $asset = $rel.assets | Where-Object { $_.name -match 'amd64\.exe$' } | Select-Object -First 1
    if ($asset) { $pythonUrl = $asset.browser_download_url; $pythonVer = $rel.tag_name }
} catch {
    Write-Step "  GitHub API lookup failed: $_ - using fallback URL." 'Yellow'
}
if (-not $pythonUrl) {
    $pythonUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe'
    $pythonVer = '3.12.10-fallback'
}
Write-Step "  Python version: $pythonVer"
try {
    $sz = Invoke-Fetch $pythonUrl (Join-Path $BundledDir 'ME_Python_3_12.exe')
    $manifest.Add([pscustomobject]@{ Package='Python 3.12'; Version=$pythonVer; File='ME_Python_3_12.exe'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: Python download failed: $_ - skipping." 'Yellow'
}

# ── 6. GitHub CLI ─────────────────────────────────────────────────────────────
Write-Step 'Resolving GitHub CLI installer…'
try {
    $gh = Resolve-GitHubLatest 'cli/cli' 'windows_amd64\.msi$'
    Write-Step "  GitHub CLI version: $($gh.Version)  ($($gh.Name))"
    $sz = Invoke-Fetch $gh.Url (Join-Path $BundledDir 'ME_GitHub_CLI.msi')
    $manifest.Add([pscustomobject]@{ Package='GitHub CLI'; Version=$gh.Version; File='ME_GitHub_CLI.msi'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: GitHub CLI download failed: $_ - skipping." 'Yellow'
}

# ── 7. Terraform ──────────────────────────────────────────────────────────────
Write-Step 'Resolving Terraform installer…'
try {
    $cp  = Invoke-RestMethod 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
    $ver = $cp.current_version
    $tfUrl = "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip"
    Write-Step "  Terraform version: $ver"
    $sz = Invoke-Fetch $tfUrl (Join-Path $BundledDir 'ME_Terraform.zip')
    $manifest.Add([pscustomobject]@{ Package='Terraform'; Version=$ver; File='ME_Terraform.zip'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: Terraform download failed: $_ - skipping." 'Yellow'
}

# ── 8. nvm-windows (required — nvm is a mandatory dependency for Node/Claude) ──
Write-Step 'Resolving nvm-windows portable zip…'
try {
    $nvm = Resolve-GitHubLatest 'coreybutler/nvm-windows' '^nvm-noinstall\.zip$'
    Write-Step "  nvm-windows version: $($nvm.Version)  ($($nvm.Name))"
    $sz = Invoke-Fetch $nvm.Url (Join-Path $BundledDir 'ME_nvm_windows.zip')
    $manifest.Add([pscustomobject]@{ Package='nvm-windows'; Version=$nvm.Version; File='ME_nvm_windows.zip'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: nvm-windows download failed: $_ - skipping." 'Yellow'
}

# ── 9. PowerShell 7 (required — Choco hung 52 min in Run 7; bundle to guarantee install) ──
Write-Step 'Resolving PowerShell 7 installer…'
try {
    $ps = Resolve-GitHubLatest 'PowerShell/PowerShell' 'win-x64\.msi$'
    Write-Step "  PowerShell version: $($ps.Version)  ($($ps.Name))"
    $sz = Invoke-Fetch $ps.Url (Join-Path $BundledDir 'ME_PowerShell_7.msi')
    $manifest.Add([pscustomobject]@{ Package='PowerShell 7'; Version=$ps.Version; File='ME_PowerShell_7.msi'; SizeMB=[math]::Round($sz,1) })
} catch {
    Write-Step "  WARNING: PowerShell 7 download failed: $_ - skipping." 'Yellow'
}

# ── 10. Write VERSIONS.md manifest ───────────────────────────────────────────
Write-Step 'Writing VERSIONS.md manifest…'
$commitHash = try { (& git -C $ProjectRoot rev-parse --short HEAD 2>&1).Trim() } catch { 'unknown' }
$lines = @(
    "# Bundled Installer Versions"
    ""
    "Built: $buildDate"
    "Commit: $commitHash"
    ""
    "| Package | Version | File | Size |"
    "|---------|---------|------|------|"
)
foreach ($m in $manifest) {
    $lines += "| $($m.Package) | $($m.Version) | $($m.File) | $($m.SizeMB) MB |"
}
$lines += ""
$lines += "**Not bundled** (downloaded at runtime by the installer):"
$lines += "- Docker Desktop  (~600 MB - Chocolatey + direct fallback)"
$lines += "- Claude Desktop  (MSIX - direct download)"
$lines += ""
$lines += "Re-run Package-Release.ps1 before each deployment wave to refresh bundled versions."
$lines | Set-Content (Join-Path $BundledDir 'VERSIONS.md') -Encoding UTF8
# Also copy to project root — uploaded as a separate release asset so Deploy-DevEnvironment.ps1
# can fetch just this file (a few KB) to decide whether the full zip needs downloading.
Copy-Item (Join-Path $BundledDir 'VERSIONS.md') (Join-Path $ProjectRoot 'VERSIONS.md') -Force
Write-Step "  VERSIONS.md written." 'Green'

# ── 11. Verify all required bundles are present before packaging ───────────────
Write-Step 'Verifying required bundles…'
$requiredBundles = @(
    'ME_Git_for_Windows.exe',
    'ME_Visual_Studio_Code.exe',
    'ME_PowerShell_7.msi',
    'ME_nvm_windows.zip',
    'ME_Python_3_12.exe',
    'ME_GitHub_CLI.msi',
    'ME_AWS_CLI_v2.msi',
    'ME_Terraform.zip'
)
$missing = $requiredBundles | Where-Object { -not (Test-Path (Join-Path $BundledDir $_)) }
if ($missing) {
    throw "Required bundled installers missing - fix downloads before packaging:`n  $($missing -join "`n  ")"
}
Write-Step "  All required bundles present." 'Green'

# ── 11b. Syntax-check all scripts before packaging ───────────────────────────
Write-Step 'Syntax-checking scripts…'
$scriptFiles = Get-ChildItem -Path (Join-Path $ProjectRoot 'scripts') -Filter '*.ps1' -File
$syntaxErrors = $false
foreach ($sf in $scriptFiles) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($sf.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-Step "  SYNTAX ERROR in $($sf.Name):" 'Red'
        foreach ($e in $parseErrors) { Write-Step "    Line $($e.Extent.StartLineNumber): $($e.Message)" 'Red' }
        $syntaxErrors = $true
    } else {
        Write-Step "  OK: $($sf.Name)" 'DarkGreen'
    }
}
if ($syntaxErrors) {
    throw "One or more scripts failed syntax check — fix errors before packaging."
}

# ── 12. Build zip ─────────────────────────────────────────────────────────────
Write-Step 'Building claude-setup-automation.zip…'
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

$include = @(
    (Join-Path $ProjectRoot 'scripts'),
    (Join-Path $ProjectRoot 'bundled')
) | Where-Object { Test-Path $_ }

Compress-Archive -Path $include -DestinationPath $ZipPath -CompressionLevel Optimal

$zipSize = (Get-Item $ZipPath).Length / 1MB
Write-Step ("Package ready: {0}  ({1:F1} MB)" -f $ZipPath, $zipSize) 'Green'
Write-Step ''
Write-Step 'Bundled versions:' 'White'
$manifest | ForEach-Object { Write-Step "  $($_.Package.PadRight(18)) $($_.Version)" 'White' }
Write-Step ''
Write-Step 'Upload both assets to the GitHub Release:' 'Green'
Write-Step '  gh release upload v1.0 claude-setup-automation.zip VERSIONS.md --clobber' 'Green'

# ── 13. Stamp NinjaOne scripts with current git commit hash ───────────────────
Write-Step ''
Write-Step 'Stamping NinjaOne scripts with current git commit hash…'
try {
    $hash = (& git -C $ProjectRoot rev-parse --short HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0 -or $hash -notmatch '^[0-9a-f]{7}$') {
        Write-Step "  WARNING: Could not read git commit hash (got: '$hash') - skipping stamp." 'Yellow'
    } else {
        $ninjaScripts = @('Deploy-DevEnvironment.ps1', 'Rollback-DevEnvironment.ps1')
        foreach ($scriptName in $ninjaScripts) {
            $scriptPath = Join-Path $PSScriptRoot $scriptName
            $content    = [System.IO.File]::ReadAllText($scriptPath)
            $stamped    = $content -replace '\$ScriptVersion\s*=\s*''[^'']*''', "`$ScriptVersion = '$hash'"
            if ($stamped -ne $content) {
                $utf8bom = New-Object System.Text.UTF8Encoding $true
                [System.IO.File]::WriteAllText($scriptPath, $stamped, $utf8bom)
                Write-Step "  Stamped: $scriptName  (commit $hash)" 'Green'
            } else {
                Write-Step "  WARNING: `$ScriptVersion line not found in $scriptName - not stamped." 'Yellow'
            }
        }
        Write-Step ''
        Write-Step 'NEXT STEPS:' 'Yellow'
        Write-Step "  1. Copy the stamped scripts into NinjaOne (both show commit $hash)." 'Yellow'
        Write-Step '  2. Restore the placeholder in the repo so git stays clean:' 'Yellow'
        Write-Step '       git checkout -- scripts/Deploy-DevEnvironment.ps1 scripts/Rollback-DevEnvironment.ps1' 'Yellow'
    }
} catch {
    Write-Step "  WARNING: Stamp step failed: $_" 'Yellow'
}
