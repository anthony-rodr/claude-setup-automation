#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Silent, self-healing developer environment installer for Master Electronics.
    Deployed via NinjaOne RMM — zero user interaction required.

.DESCRIPTION
    Three-tier install strategy per package: winget → Chocolatey → direct download.
    Each tier self-heals before falling back (repairs winget sources, re-downloads
    Chocolatey, diagnoses network/lock/agreement errors and retries).
    Records every install into a manifest consumed by Rollback-DevEnvironment.ps1.
    After machine-wide installs, configures all existing user profiles and registers
    a scheduled task so future user accounts are configured on first logon.

.PREREQUISITES
    ── IT / Deployment ────────────────────────────────────────────────────────
    1. Anthropic API Key (required for the setup guide chatbot)
       - The chatbot that guides employees through post-install configuration is
         powered by the Anthropic API. This requires ONE company-level API key.
       - Obtain from: console.anthropic.com → API Keys → Create Key
         (Sign in with the company's existing Anthropic/Claude billing account)
       - Pass it to this script via: -AnthropicApiKey "sk-ant-..."
       - The key is stored as a machine-level environment variable so every user
         on the machine can run the chatbot — employees never need to see it.
       - Cost: pay-per-use API calls, roughly $0.01–0.03 per setup conversation.

    ── Per Employee (guided by the chatbot after install) ─────────────────────
    2. Claude Account (required for Claude Code)
       - Each employee needs their own free Claude account at claude.ai to
         authenticate Claude Code. This is a personal account, separate from
         the company API key above.
       - The setup guide chatbot walks employees through creating or signing into
         their Claude account and completing OAuth authentication (Step 6).
       - Employees do NOT need billing — a free claude.ai account is sufficient.

    ── Summary ────────────────────────────────────────────────────────────────
    IT manages:  One Anthropic API key (console.anthropic.com, company account)
    Each user:   One free Claude account (claude.ai, personal, guided by chatbot)

.PARAMETER Role
    Which tool set to install.  Core = base tools everyone gets.
    Dev = adds nvm/Node, Python, GitHub CLI, Docker.
    CloudOps = adds AWS CLI, Terraform (also installs Core).
    All = everything (default).

.PARAMETER MaxRetries
    How many times to retry each install method before trying the next tier (default 3).

.PARAMETER LogPath
    Full path to the install log file.

.PARAMETER ManifestPath
    Full path to the JSON manifest consumed by Rollback-DevEnvironment.ps1.

.PARAMETER AnthropicApiKey
    Anthropic API key used by the developer setup guide chatbot.
    Stored as a machine-level environment variable so all users can run the chatbot.
    IT obtains this key from the Anthropic console and passes it here.

.EXAMPLE
    # Deploy from NinjaOne as SYSTEM, install everything:
    powershell.exe -ExecutionPolicy Bypass -File Install-DevEnvironment.ps1 `
        -AnthropicApiKey "sk-ant-..."

    # CloudOps role only:
    powershell.exe -ExecutionPolicy Bypass -File Install-DevEnvironment.ps1 `
        -Role CloudOps -AnthropicApiKey "sk-ant-..."
#>
[CmdletBinding()]
param(
    [ValidateSet('Core', 'Dev', 'CloudOps', 'All')]
    [string]$Role = 'All',

    [int]$MaxRetries = 3,

    [string]$LogPath = 'C:\ProgramData\MasterElectronics\DevSetup\install.log',

    [string]$ManifestPath = 'C:\ProgramData\MasterElectronics\DevSetup\manifest.json',

    # Anthropic API key for the setup guide chatbot.
    # Pass this from NinjaOne as a secret script parameter.
    [string]$AnthropicApiKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
$SetupDir     = Split-Path $ManifestPath -Parent
$ConfigScript = Join-Path $SetupDir 'Configure-UserEnvironment.ps1'
$ExtListFile  = Join-Path $SetupDir 'vscode-extensions.json'
$TaskName     = 'MasterElectronics-ConfigureUserEnvironment'

# ─────────────────────────────────────────────────────────────────────────────
# Deployment context
# winget is unreliable when running as SYSTEM (NinjaOne/RMM context) due to
# UWP/COM limitations.  Detect SYSTEM early so Install-Package can use
# Chocolatey as Tier 1 and demote winget to last-resort.
# ─────────────────────────────────────────────────────────────────────────────
$RunningAsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match 'SYSTEM'

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet('INFO','OK','WARN','FAIL','DIAG')]
        [string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'OK'   { 'Green'  }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red'    }
        'DIAG' { 'Cyan'   }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# PATH refresh helper
# Reads Machine + User PATH from registry, expands embedded %VAR% references
# (e.g. %NVM_HOME% set by Chocolatey), and updates the current session.
# Must also refresh non-PATH machine vars first so ExpandEnvironmentVariables
# can resolve them.
# ─────────────────────────────────────────────────────────────────────────────
function Update-SessionPath {
    # Refresh non-PATH machine env vars (ChocolateyInstall, etc.) then user env
    # vars (NVM_HOME when nvm is installed per-user via winget) so that
    # ExpandEnvironmentVariables can resolve %VAR% references in PATH strings.
    foreach ($scope in 'Machine','User') {
        $vars = [System.Environment]::GetEnvironmentVariables($scope)
        foreach ($key in $vars.Keys) {
            if ($key -ne 'Path') {
                Set-Item -Path "Env:\$key" -Value $vars[$key] -ErrorAction SilentlyContinue
            }
        }
    }
    $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $up = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $mp) { $mp = '' }
    if (-not $up) { $up = '' }
    $env:Path = ([System.Environment]::ExpandEnvironmentVariables($mp) + ';' +
                 [System.Environment]::ExpandEnvironmentVariables($up)).TrimEnd(';')
}

# ─────────────────────────────────────────────────────────────────────────────
# Manifest
# ─────────────────────────────────────────────────────────────────────────────
$Manifest = [ordered]@{
    SchemaVersion = '1.0'
    StartTime     = (Get-Date -Format 'o')
    Role          = $Role
    Packages      = [System.Collections.Generic.List[object]]::new()
    ChocolateyInstalled = $false
    Errors        = [System.Collections.Generic.List[string]]::new()
}

function Save-Manifest {
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content $ManifestPath -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# Package catalog
# Each entry: Name, Roles[], Winget, Choco, Direct (scriptblock → URL),
#             DArgs (silent args), DType (exe|msi|msix|exe-args|zip-to-path)
# ─────────────────────────────────────────────────────────────────────────────
$Packages = @(
    @{
        Name   = 'Git for Windows'
        Roles  = @('Core', 'Dev', 'CloudOps', 'All')
        Winget = 'Git.Git'
        Choco  = 'git'
        Direct = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
            ($r.assets | Where-Object { $_.name -match '-64-bit\.exe$' }).browser_download_url
        }
        DArgs  = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"'
        DType  = 'exe'
    }
    @{
        Name      = 'Visual Studio Code'
        Roles     = @('Core', 'Dev', 'CloudOps', 'All')
        Winget    = 'Microsoft.VisualStudioCode'
        Choco     = 'vscode'
        VerifyExe = 'C:\Program Files\Microsoft VS Code\Code.exe'
        Direct    = {
            # The /latest redirect resolves to the current stable installer
            'https://update.code.visualstudio.com/latest/win32-x64/stable'
        }
        DArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'
        DType     = 'exe'
    }
    @{
        Name   = 'PowerShell 7'
        Roles  = @('Core', 'Dev', 'CloudOps', 'All')
        Winget = 'Microsoft.PowerShell'
        Choco  = 'powershell-core'
        Direct = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            ($r.assets | Where-Object { $_.name -match 'win-x64\.msi$' -and $_.name -notmatch 'preview' }).browser_download_url
        }
        DArgs  = '/quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1'
        DType  = 'msi'
    }
    @{
        Name    = 'nvm-windows'
        Roles   = @('Dev', 'All')
        Winget  = $null     # winget installs nvm per-user (AppData) — must be machine-wide for all users
        Choco   = $null     # choco nvm silently no-ops as SYSTEM
        # nvm-noinstall.zip extracts nvm.exe to ZipDest — machine-wide, no installer UI.
        # We write settings.txt and set machine env vars in Install-ClaudeCode.
        Direct  = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/coreybutler/nvm-windows/releases/latest'
            ($r.assets | Where-Object { $_.name -eq 'nvm-noinstall.zip' }).browser_download_url
        }
        DType   = 'zip-to-path'
        ZipDest = 'C:\ProgramData\nvm'
    }
    @{
        Name   = 'Python 3.12'
        Roles  = @('Dev', 'All')
        Winget = 'Python.Python.3.12'
        Choco  = $null   # choco python312 exits 1603 when registry remnants exist; use direct/winget
        Direct = {
            try {
                $releases = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
                $rel = $releases | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } |
                       Select-Object -First 1
                $asset = $rel.assets | Where-Object { $_.name -match 'amd64\.exe$' }
                if ($asset) { return $asset.browser_download_url }
            } catch { }
            # Fallback to known stable
            'https://www.python.org/ftp/python/3.12.9/python-3.12.9-amd64.exe'
        }
        DArgs      = '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0'
        DType      = 'exe'
        VerifyCmd  = 'python'   # Skip install if python is already functional
        # Known machine-wide install paths — used as fallback when 1638 persists after uninstall attempt
        AltPaths  = @(
            'C:\Program Files\Python312',
            'C:\Program Files\Python313',
            'C:\Program Files\Python311',
            'C:\Python312',
            'C:\Python3'
        )
    }
    @{
        Name   = 'GitHub CLI'
        Roles  = @('Dev', 'All')
        Winget = 'GitHub.cli'
        Choco  = 'gh'
        Direct = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest'
            ($r.assets | Where-Object { $_.name -match 'windows_amd64\.msi$' }).browser_download_url
        }
        DArgs  = '/quiet /norestart'
        DType  = 'msi'
    }
    @{
        # WSL2 must be installed before Docker Desktop (Docker requires it for the wsl-2 backend).
        # Installs the WSL2 kernel only — no Linux distro.  A reboot is required for WSL to
        # become active; NinjaOne should be configured to restart the machine after this script.
        Name   = 'Windows Subsystem for Linux 2'
        Roles  = @('Dev', 'All')
        Winget = 'Microsoft.WSL'
        Choco  = $null
        Direct = $null
        DArgs  = '--install --no-distribution'
        DType  = 'wsl-install'
    }
    @{
        Name   = 'Docker Desktop'
        Roles  = @('Dev', 'All')
        Winget = 'Docker.DockerDesktop'
        Choco  = 'docker-desktop'
        Direct = {
            'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
        }
        DArgs  = 'install --quiet --accept-license --backend=wsl-2'
        DType  = 'exe-args'
    }
    @{
        Name   = 'AWS CLI v2'
        Roles  = @('CloudOps', 'All')
        Winget = 'Amazon.AWSCLI'
        Choco  = 'awscli'
        Direct = {
            'https://awscli.amazonaws.com/AWSCLIV2.msi'
        }
        DArgs  = '/quiet /norestart'
        DType  = 'msi'
    }
    @{
        Name   = 'Terraform'
        Roles  = @('CloudOps', 'All')
        Winget = 'Hashicorp.Terraform'
        Choco  = 'terraform'
        Direct = {
            $cp  = Invoke-RestMethod 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
            $ver = $cp.current_version
            "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip"
        }
        DArgs  = $null
        DType  = 'zip-to-path'
        ZipDest = 'C:\Program Files\Terraform'
    }
)

# ─────────────────────────────────────────────────────────────────────────────
# VS Code extensions — installed per-user by Configure-UserEnvironment.ps1
# ─────────────────────────────────────────────────────────────────────────────
$VsCodeExtensions = @(
    'ms-vscode.PowerShell'
    'ms-python.python'        # Pylance ships as a dependency — no separate entry needed
    'hashicorp.terraform'
    'amazonwebservices.aws-toolkit-vscode'
    'GitHub.vscode-pull-request-github'
    'eamodio.gitlens'
    'ms-vscode-remote.remote-wsl'
    'esbenp.prettier-vscode'
    'dbaeumer.vscode-eslint'
    'ms-azuretools.vscode-docker'
)

# ─────────────────────────────────────────────────────────────────────────────
# Network / TLS helpers
# ─────────────────────────────────────────────────────────────────────────────
function Set-TlsPolicy {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}

function Invoke-Download {
    param([string]$Url, [string]$Dest)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        # Remove any partial file from a previous failed attempt before retrying —
        # Invoke-WebRequest can leave a locked/partial file on failure.
        if (Test-Path $Dest) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue }
        try {
            Invoke-WebRequest $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
            return
        } catch {
            if ($i -eq $MaxRetries) { throw }
            Write-Log "Download attempt $i failed ($Url) — retrying in 10 s." 'WARN'
            Start-Sleep -Seconds 10
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# winget — self-healing
# ─────────────────────────────────────────────────────────────────────────────
function Repair-WingetSources {
    Write-Log 'Resetting and refreshing winget sources…' 'DIAG'
    try {
        & winget source reset --force 2>&1 | Out-Null
        & winget source update         2>&1 | Out-Null
        Write-Log 'winget sources refreshed.' 'OK'
    } catch {
        Write-Log "Source refresh warning: $_" 'WARN'
    }
}

function Ensure-Winget {
    [OutputType([bool])]
    param()

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $v = (& winget --version 2>&1) -replace '[^\d\.]'
        Write-Log "winget $v is present." 'DIAG'
        return $true
    }

    # MSIX installation requires a user session — always fails under SYSTEM.
    if ($RunningAsSystem) {
        Write-Log 'winget not found and cannot be repaired under SYSTEM — skipping.' 'DIAG'
        return $false
    }

    Write-Log 'winget not found — repairing via App Installer MSIX…' 'WARN'

    # Method 1: Microsoft's redirect (aka.ms/getwinget)
    try {
        $tmp = Join-Path $env:TEMP 'AppInstaller.msixbundle'
        Invoke-Download 'https://aka.ms/getwinget' $tmp
        Add-AppxPackage -Path $tmp -ForceApplicationShutdown -ErrorAction Stop
        Write-Log 'App Installer installed from aka.ms/getwinget.' 'OK'
        return $true
    } catch {
        Write-Log "App Installer MSIX (aka.ms) failed: $_" 'WARN'
    }

    # Method 2: GitHub latest release
    try {
        $r   = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
        $url = ($r.assets | Where-Object { $_.name -match '\.msixbundle$' }).browser_download_url
        $tmp = Join-Path $env:TEMP 'winget-latest.msixbundle'
        Invoke-Download $url $tmp
        Add-AppxPackage -Path $tmp -ForceApplicationShutdown -ErrorAction Stop
        Write-Log 'winget installed from GitHub release.' 'OK'
        return $true
    } catch {
        Write-Log "winget GitHub fallback failed: $_" 'FAIL'
        return $false
    }
}

function Install-ViaWinget {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    if (-not $Pkg.Winget) { return $false }
    $id = $Pkg.Winget

    Write-Log "  winget upgrade/install $id…" 'DIAG'

    for ($i = 1; $i -le $MaxRetries; $i++) {
        # Try upgrade first — no-ops if already at latest, reports "No installed package found" if absent
        Write-Log "  winget upgrade $id (attempt $i)…" 'DIAG'
        $out = & winget upgrade --id $id --silent `
               --accept-package-agreements --accept-source-agreements --scope machine 2>&1
        $raw = ($out -join "`n")

        if ($LASTEXITCODE -eq 0 -or $raw -match '(?i)no applicable upgrade|already installed') {
            Write-Log "  winget OK (up to date): $id" 'OK'
            return $true
        }

        if ($raw -match '(?i)No installed package found|not installed') {
            # Package is absent — fall through to install
            Write-Log "  $id not yet installed — running winget install…" 'DIAG'
            $out = & winget install --id $id --silent `
                   --accept-package-agreements --accept-source-agreements `
                   --scope machine 2>&1
            $raw = ($out -join "`n")
            if ($LASTEXITCODE -eq 0 -or $raw -match '(?i)already installed') {
                Write-Log "  winget install OK: $id" 'OK'
                return $true
            }
        }

        # Diagnose and heal before next attempt
        if ($raw -match '(?i)No package found') {
            Write-Log "  Package '$id' not in winget catalog — skipping tier." 'WARN'
            return $false
        }
        if ($raw -match '(?i)source agreements') {
            Write-Log "  Source agreement error — refreshing sources." 'DIAG'
            Repair-WingetSources
        } elseif ($raw -match '(?i)timeout|network|unable to connect|no internet') {
            Write-Log "  Network error (attempt $i) — waiting 15 s." 'DIAG'
            Start-Sleep -Seconds 15
        } elseif ($raw -match '(?i)another installation is in progress|locked|access is denied') {
            Write-Log "  Process lock (attempt $i) — waiting 30 s." 'DIAG'
            Start-Sleep -Seconds 30
        } else {
            Write-Log "  winget error (attempt $i/$MaxRetries): exit $LASTEXITCODE" 'WARN'
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds 5 }
        }
    }
    Write-Log "  winget exhausted after $MaxRetries attempts for $id." 'WARN'
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Chocolatey — self-healing
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-Chocolatey {
    [OutputType([bool])]
    param()

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $v = (& choco --version 2>&1)[0]
        Write-Log "Chocolatey $v is present." 'DIAG'
        return $true
    }

    Write-Log 'Installing Chocolatey…' 'DIAG'
    try {
        Set-TlsPolicy
        $script = (Invoke-WebRequest 'https://community.chocolatey.org/install.ps1' -UseBasicParsing).Content
        Invoke-Expression $script
        # Re-source PATH so choco is findable
        Update-SessionPath
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Log 'Chocolatey installed.' 'OK'
            $Manifest.ChocolateyInstalled = $true
            Save-Manifest
            return $true
        }
    } catch {
        Write-Log "Chocolatey install failed: $_" 'FAIL'
    }
    return $false
}

function Install-ViaChocolatey {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    if (-not $Pkg.Choco) { return $false }
    if (-not (Ensure-Chocolatey))  { return $false }

    $id = $Pkg.Choco
    Write-Log "  choco upgrade $id…" 'DIAG'

    for ($i = 1; $i -le $MaxRetries; $i++) {
        # choco upgrade installs if absent, upgrades if present — inherently idempotent
        $out = & choco upgrade $id --yes --no-progress 2>&1
        $raw = ($out -join "`n")

        # Only treat "already installed" as success when it refers to THIS package,
        # not a dependency — prevents false positives from vcredist/KB entries.
        $pkgAlreadyPresent = $raw -match "(?i)$([regex]::Escape($id)).*(already installed|is the latest version)"
        if ($LASTEXITCODE -eq 0 -or $pkgAlreadyPresent) {
            Write-Log "  choco OK: $id" 'OK'
            Write-Log "  choco output: $raw" 'DIAG'
            # If VerifyExe is defined and the binary is absent, choco hit a ghost registry
            # entry and skipped the actual install.  Force a reinstall to lay down the files.
            $verifyExe = if ($Pkg.ContainsKey('VerifyExe')) { $Pkg['VerifyExe'] } else { $null }
            if ($verifyExe -and -not (Test-Path $verifyExe)) {
                Write-Log "  VerifyExe missing after choco ($verifyExe) — forcing reinstall…" 'WARN'
                $out2 = & choco install $id --yes --no-progress --force 2>&1
                Write-Log "  choco --force output: $($out2 -join "`n")" 'DIAG'
            }
            return $true
        }

        if ($raw -match '(?i)timeout|network|unable to connect') {
            Write-Log "  Choco network issue (attempt $i) — waiting 15 s." 'DIAG'
            Start-Sleep -Seconds 15
        } elseif ($raw -match '(?i)locked|access is denied') {
            Write-Log "  Choco lock (attempt $i) — waiting 30 s." 'DIAG'
            Start-Sleep -Seconds 30
        } else {
            Write-Log "  Choco error (attempt $i/$MaxRetries): exit $LASTEXITCODE" 'WARN'
            Write-Log "  choco output: $raw" 'DIAG'
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds 5 }
        }
    }
    Write-Log "  Choco exhausted for $id." 'WARN'
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Direct download — self-healing
# ─────────────────────────────────────────────────────────────────────────────
function Install-ViaDirectDownload {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    # ── WSL — built-in Windows command, no download needed ──────────────────
    if ($Pkg.DType -eq 'wsl-install') {
        Write-Log "  Installing WSL via: wsl.exe $($Pkg.DArgs)" 'DIAG'
        try {
            $p = Start-Process 'wsl.exe' -ArgumentList ($Pkg.DArgs -split '\s+') `
                     -Wait -PassThru -NoNewWindow
            # 0 = success; 1 = success but reboot required (normal on first install)
            if ($p.ExitCode -in @(0, 1)) {
                Write-Log '  WSL installed OK — reboot required to fully activate WSL2.' 'OK'
                return $true
            }
            throw "wsl.exe exited $($p.ExitCode)"
        } catch {
            Write-Log "  WSL direct install failed: $_" 'WARN'
            return $false
        }
    }

    if (-not $Pkg.Direct) { return $false }

    $ext = switch ($Pkg.DType) {
        'msi'         { '.msi' }
        'zip-to-path' { '.zip' }
        'msix'        { '.msix' }
        default       { '.exe' }
    }
    $tmpFileName  = "ME_$($Pkg.Name -replace '[^\w]','_')$ext"

    # ── Bundled installer check ───────────────────────────────────────────────
    # Package-Release.ps1 pre-downloads Python and VS Code into bundled/ so they
    # ship inside the zip.  Use the bundled copy when available — avoids a network
    # download for the two most failure-prone packages.
    $bundledDir   = Join-Path $PSScriptRoot '..\bundled'
    $bundledFile  = Join-Path $bundledDir $tmpFileName
    $tmpFile      = $null
    $isFromBundle = $false

    if (Test-Path $bundledFile) {
        Write-Log "  Bundled installer found — skipping download: $bundledFile" 'OK'
        $tmpFile      = $bundledFile
        $isFromBundle = $true
    } else {
        Write-Log "  Resolving direct download URL for $($Pkg.Name)…" 'DIAG'
        $url = $null
        try { $url = & $Pkg.Direct } catch {
            Write-Log "  URL resolution failed: $_" 'WARN'
            return $false
        }
        if (-not $url) {
            Write-Log '  Direct URL resolved to null.' 'WARN'
            return $false
        }

        $tmpFile = Join-Path $env:TEMP $tmpFileName
        Write-Log "  Downloading: $url" 'DIAG'
        try { Invoke-Download $url $tmpFile } catch {
            Write-Log "  Download failed: $_" 'FAIL'
            return $false
        }
    }

    try {
        switch ($Pkg.DType) {
            'exe' {
                $p = Start-Process $tmpFile -ArgumentList $Pkg.DArgs -Wait -PassThru -NoNewWindow
                # 1638 = another version already registered in Programs & Features.
                # Uninstall the conflicting entry via the registry, then retry once.
                if ($p.ExitCode -eq 1638) {
                    Write-Log "  Exit 1638 — existing version registered. Attempting registry uninstall of '$($Pkg.Name)'…" 'WARN'
                    $uninstallKeys = @(
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    )
                    # Guard against strict-mode crash: registry entries may lack DisplayName entirely.
                    $entry = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
                             Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*$($Pkg.Name)*" } |
                             Select-Object -First 1
                    $usProp = if ($entry) { $entry.PSObject.Properties['UninstallString'] } else { $null }
                    if ($usProp -and $usProp.Value) {
                        $us = $usProp.Value
                        if ($us -match 'msiexec') {
                            $code = [regex]::Match($us, '\{[^}]+\}').Value
                            Start-Process msiexec.exe -ArgumentList "/x $code /quiet /norestart" -Wait -NoNewWindow | Out-Null
                        } else {
                            if ($us -match '^"([^"]+)"(.*)$') { $unExe = $Matches[1]; $unArgs = $Matches[2].Trim() }
                            else { $unExe = ($us -split ' ',2)[0]; $unArgs = ($us -split ' ',2)[1] }
                            Start-Process $unExe -ArgumentList "$unArgs /SILENT /NORESTART" -Wait -NoNewWindow | Out-Null
                        }
                        Write-Log "  Registry uninstall complete." 'DIAG'
                    } else {
                        Write-Log "  No registry UninstallString found." 'WARN'
                    }
                    # Always run the bundled installer's own /uninstall after any registry-based
                    # attempt.  Python bundles several sub-MSIs (Executables, Standard Library,
                    # pip, etc.) — the registry uninstall only removes the wrapper product code.
                    # The EXE /uninstall removes every sub-MSI atomically, clearing 1638 reliably.
                    Write-Log "  Running installer /uninstall to remove all sub-components…" 'DIAG'
                    $pUn = Start-Process $tmpFile -ArgumentList '/quiet /uninstall' -Wait -PassThru -NoNewWindow
                    Write-Log "  Installer /uninstall exited $($pUn.ExitCode)" 'DIAG'
                    # Clean MSI product database — Python's EXE installer checks
                    # HKLM\SOFTWARE\Classes\Installer\Products\ (MSI internal DB), which
                    # survives ordinary Uninstall key deletion and causes persistent 1638.
                    $msiProductsPath = 'HKLM:\SOFTWARE\Classes\Installer\Products'
                    if (Test-Path $msiProductsPath) {
                        Get-ChildItem $msiProductsPath -ErrorAction SilentlyContinue | ForEach-Object {
                            $mp  = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                            $mpn = if ($mp -and $mp.PSObject.Properties['ProductName']) { $mp.PSObject.Properties['ProductName'].Value } else { $null }
                            if ($mpn -and $mpn -like "*$($Pkg.Name.Split(' ')[0])*") {
                                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                                Write-Log "  Removed MSI product registration: $mpn" 'DIAG'
                            }
                        }
                    }
                    # Also clean per-user MSI data (machine installs land under S-1-5-18)
                    $msiUserDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
                    if (Test-Path $msiUserDataRoot) {
                        Get-ChildItem $msiUserDataRoot -ErrorAction SilentlyContinue | ForEach-Object {
                            $productsKey = Join-Path $_.PSPath 'Products'
                            if (Test-Path $productsKey) {
                                Get-ChildItem $productsKey -ErrorAction SilentlyContinue | ForEach-Object {
                                    $ipKey = Join-Path $_.PSPath 'InstallProperties'
                                    $ip = Get-ItemProperty $ipKey -ErrorAction SilentlyContinue
                                    $ipn = if ($ip -and $ip.PSObject.Properties['DisplayName']) { $ip.PSObject.Properties['DisplayName'].Value } else { $null }
                                    if ($ipn -and $ipn -like "*$($Pkg.Name.Split(' ')[0])*") {
                                        Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                                        Write-Log "  Removed MSI UserData entry: $ipn" 'DIAG'
                                    }
                                }
                            }
                        }
                    }
                    $p = Start-Process $tmpFile -ArgumentList $Pkg.DArgs -Wait -PassThru -NoNewWindow
                    # If still 1638, the uninstall didn't fully clear it.
                    # Find the existing install directory and add it to PATH — Python is
                    # already functional, it just isn't on PATH.
                    if ($p.ExitCode -eq 1638 -and $Pkg.ContainsKey('AltPaths')) {
                        Write-Log "  Still 1638 after uninstall — scanning for existing install…" 'WARN'
                        $altDir = $Pkg.AltPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
                        if ($altDir) {
                            $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
                            if ($mp -notlike "*$altDir*") {
                                [System.Environment]::SetEnvironmentVariable('Path', "$mp;$altDir", 'Machine')
                                $env:Path = "$env:Path;$altDir"
                                Write-Log "  Added existing install to machine PATH: $altDir" 'OK'
                            } else {
                                Write-Log "  Existing install already in PATH: $altDir" 'DIAG'
                            }
                            Write-Log "  Direct install OK (pre-existing): $($Pkg.Name)" 'OK'
                            return $true
                        }
                    }
                }
                if ($p.ExitCode -notin @(0, 3010)) { throw "Exit code $($p.ExitCode)" }
            }
            'exe-args' {
                # Args are passed as a single string to the EXE (e.g. Docker Desktop)
                $p = Start-Process $tmpFile -ArgumentList $Pkg.DArgs -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -notin @(0, 3010)) { throw "Exit code $($p.ExitCode)" }
            }
            'msi' {
                $p = Start-Process msiexec.exe -ArgumentList "/i `"$tmpFile`" $($Pkg.DArgs)" `
                     -Wait -PassThru -NoNewWindow
                if ($p.ExitCode -notin @(0, 3010)) { throw "msiexec exit $($p.ExitCode)" }
            }
            'msix' {
                Add-AppxPackage -Path $tmpFile -ErrorAction Stop
            }
            'zip-to-path' {
                $dest = if ($Pkg.ZipDest) { $Pkg.ZipDest } else { 'C:\Program Files\ZipInstall' }
                if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                Expand-Archive -Path $tmpFile -DestinationPath $dest -Force
                # Add to machine PATH if not already present
                $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
                if ($mp -notlike "*$dest*") {
                    [System.Environment]::SetEnvironmentVariable('Path', "$mp;$dest", 'Machine')
                    $env:Path = $env:Path + ";$dest"
                }
            }
        }
        Write-Log "  Direct install OK: $($Pkg.Name)" 'OK'
        return $true
    } catch {
        Write-Log "  Direct install error: $_" 'FAIL'
        return $false
    } finally {
        # Never delete a bundled installer — it lives inside the zip and cannot be re-downloaded.
        if (-not $isFromBundle) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Package orchestrator — winget → Choco → direct
# ─────────────────────────────────────────────────────────────────────────────
function Install-Package {
    param([hashtable]$Pkg)

    # Role filter
    $inRole = $Role -eq 'All' -or 'All' -in $Pkg.Roles -or $Role -in $Pkg.Roles
    if (-not $inRole) {
        Write-Log "Skip '$($Pkg.Name)' (not in role '$Role')." 'DIAG'
        return
    }

    Write-Log "=== $($Pkg.Name) ===" 'INFO'

    $entry = [ordered]@{
        Name      = $Pkg.Name
        Timestamp = (Get-Date -Format 'o')
        Method    = $null
        WingetId  = $Pkg.Winget
        ChocoId   = $Pkg.Choco
        Success   = $false
    }

    # Pre-check: if VerifyCmd is defined and the tool is already functional, skip install entirely.
    # Handles cases where the tool was installed manually or by a prior run that left it working.
    # Use ContainsKey to avoid StrictMode throwing on packages that don't define this property.
    $preCheckCmd = if ($Pkg.ContainsKey('VerifyCmd')) { $Pkg['VerifyCmd'] } else { $null }
    if ($preCheckCmd -and (Get-Command $preCheckCmd -ErrorAction SilentlyContinue)) {
        $existVer = try { (& $preCheckCmd '--version' 2>&1 | Select-Object -First 1) -replace '\s+$','' } catch { 'present' }
        Write-Log "  $($Pkg.Name) already installed ($existVer) — skipping." 'OK'
        $entry.Method  = 'pre-existing'
        $entry.Success = $true
        $Manifest.Packages.Add($entry)
        Save-Manifest
        return
    }

    if ($RunningAsSystem) {
        # SYSTEM context (NinjaOne): Chocolatey → Direct → winget (last resort)
        # winget has UWP/COM limitations as SYSTEM; Chocolatey is purpose-built for headless installs.

        # Tier 1 — Chocolatey
        if (Install-ViaChocolatey $Pkg) {
            $entry.Method  = 'choco'
            $entry.Success = $true
        }

        # Tier 2 — direct download
        if (-not $entry.Success) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method  = 'direct'
                $entry.Success = $true
            }
        }

        # Tier 3 — winget (last resort; some packages only have a winget entry)
        if (-not $entry.Success) {
            if (Ensure-Winget) {
                if (Install-ViaWinget $Pkg) {
                    $entry.Method  = 'winget'
                    $entry.Success = $true
                }
            }
        }
    } else {
        # Interactive context: winget → Chocolatey → Direct
        Write-Log "  Running interactively — using winget → Chocolatey → Direct." 'DIAG'

        # Tier 1 — winget
        if (Ensure-Winget) {
            if (Install-ViaWinget $Pkg) {
                $entry.Method  = 'winget'
                $entry.Success = $true
            }
        }

        # Tier 2 — Chocolatey
        if (-not $entry.Success) {
            if (Install-ViaChocolatey $Pkg) {
                $entry.Method  = 'choco'
                $entry.Success = $true
            }
        }

        # Tier 3 — direct download
        if (-not $entry.Success) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method  = 'direct'
                $entry.Success = $true
            }
        }
    }

    if (-not $entry.Success) {
        $msg = "FAILED to install '$($Pkg.Name)' via all available methods."
        Write-Log $msg 'FAIL'
        $Manifest.Errors.Add($msg)
    }

    $Manifest.Packages.Add($entry)
    Save-Manifest
}

# ─────────────────────────────────────────────────────────────────────────────
# Claude Code — special handling (nvm + Node + npm global)
# ─────────────────────────────────────────────────────────────────────────────
function Install-ClaudeCode {
    Write-Log '=== Claude Code ===' 'INFO'

    # Refresh PATH so newly installed tools are visible
    Update-SessionPath

    # Diagnostic snapshot before any fixup
    Write-Log "  NVM_HOME (machine): $([System.Environment]::GetEnvironmentVariable('NVM_HOME','Machine'))" 'DIAG'
    Write-Log "  NVM_HOME (user):    $([System.Environment]::GetEnvironmentVariable('NVM_HOME','User'))" 'DIAG'
    Write-Log "  PATH nvm/node: $(($env:Path -split ';' | Where-Object { $_ -match 'nvm|node' }) -join ', ')" 'DIAG'

    # ── Locate nvm.exe by direct file-system scan ─────────────────────────────
    # Get-Command caches results from before $env:Path was mutated, so it can
    # return false even when nvm.exe is present on PATH.  Scanning directly is
    # reliable regardless of cache state.
    $nvmExe     = $null
    $nvmDir     = $null
    $nvmSymlink = 'C:\Program Files\nodejs'

    $chocoLib = [System.Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    if (-not $chocoLib) { $chocoLib = 'C:\ProgramData\chocolatey' }

    $nvmCandidates = @(
        $env:NVM_HOME,
        [System.Environment]::GetEnvironmentVariable('NVM_HOME', 'Machine'),
        'C:\ProgramData\nvm',
        'C:\nvm4w', 'C:\nvm', 'C:\tools\nvm',
        'C:\Windows\System32\config\systemprofile\AppData\Roaming\nvm',
        "$env:APPDATA\nvm", "$env:LOCALAPPDATA\nvm",
        (Join-Path $chocoLib 'lib\nvm\tools'),
        (Join-Path $chocoLib 'lib\nvm.portable\tools')
    )
    # Also scan every PATH entry that looks nvm-related
    $nvmCandidates += ($env:Path -split ';') | Where-Object { $_ -match 'nvm' }

    foreach ($c in ($nvmCandidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path (Join-Path $c 'nvm.exe')) {
            $nvmExe = Join-Path $c 'nvm.exe'
            $nvmDir = $c
            Write-Log "  nvm.exe found at: $nvmExe" 'DIAG'
            break
        }
    }

    # ── Configure nvm environment (NVM_HOME, NVM_SYMLINK, PATH, settings.txt) ──
    if ($nvmExe) {
        # NVM_HOME
        if (-not [System.Environment]::GetEnvironmentVariable('NVM_HOME', 'Machine')) {
            [System.Environment]::SetEnvironmentVariable('NVM_HOME', $nvmDir, 'Machine')
            Write-Log "  NVM_HOME written to machine registry: $nvmDir" 'OK'
        }
        $env:NVM_HOME = $nvmDir

        # NVM_SYMLINK
        if (-not [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')) {
            [System.Environment]::SetEnvironmentVariable('NVM_SYMLINK', $nvmSymlink, 'Machine')
            Write-Log "  NVM_SYMLINK written to machine registry: $nvmSymlink" 'OK'
        }
        $env:NVM_SYMLINK = $nvmSymlink

        # Ensure both the nvm dir and the nodejs symlink dir are on machine PATH and session PATH
        foreach ($addPath in @($nvmDir, $nvmSymlink)) {
            $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
            if ($mp -notlike "*$addPath*") {
                [System.Environment]::SetEnvironmentVariable('Path', "$mp;$addPath", 'Machine')
                Write-Log "  Added to machine PATH: $addPath" 'OK'
            }
            if ($env:Path -notlike "*$addPath*") { $env:Path = "$env:Path;$addPath" }
        }

        # settings.txt — required by nvm-noinstall.zip; nvm refuses to run without it
        $settingsFile = Join-Path $nvmDir 'settings.txt'
        if (-not (Test-Path $settingsFile)) {
            @"
root: $nvmDir
path: $nvmSymlink
arch: 64
proxy: none
"@ | Set-Content $settingsFile -Encoding UTF8
            Write-Log "  nvm settings.txt created at $settingsFile" 'OK'
        } else {
            Write-Log "  nvm settings.txt exists at $settingsFile" 'DIAG'
        }
    } else {
        Write-Log '  nvm.exe not found — will try fallback Node.js installers.' 'WARN'
    }

    # ── Install Node.js LTS — three tiers: nvm → Chocolatey → direct MSI ──────
    $nodeOk = (Get-Command node -ErrorAction SilentlyContinue) -ne $null
    if ($nodeOk) {
        Write-Log "  Node.js already present: $(& node --version 2>&1)" 'DIAG'
    }

    # Tier 1 — direct Node.js LTS MSI from nodejs.org (machine-wide, all users inherit from PATH)
    if (-not $nodeOk) {
        Write-Log '  Installing Node.js LTS via MSI (machine-wide)…' 'DIAG'
        try {
            $index  = Invoke-RestMethod 'https://nodejs.org/dist/index.json' -UseBasicParsing
            $ltsRel = $index | Where-Object { $_.lts -and $_.lts -ne $false } | Select-Object -First 1
            $ver    = $ltsRel.version    # e.g. "v22.14.0"
            $url    = "https://nodejs.org/dist/$ver/node-$ver-x64.msi"
            $tmp    = Join-Path $env:TEMP 'ME_nodejs_lts.msi'
            Write-Log "  Downloading Node.js $ver from nodejs.org…" 'DIAG'
            Invoke-Download $url $tmp
            $p = Start-Process msiexec.exe `
                     -ArgumentList "/i `"$tmp`" /quiet /norestart ADDLOCAL=ALL" `
                     -Wait -PassThru -NoNewWindow
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -in @(0, 3010)) {
                Write-Log '  Node.js MSI install OK.' 'OK'
                Update-SessionPath
                if (Get-Command node -ErrorAction SilentlyContinue) {
                    $nodeOk = $true
                    Write-Log "  Node.js installed via MSI: $(& node --version 2>&1)" 'OK'
                }
            } else {
                Write-Log "  Node.js MSI exited $($p.ExitCode) — trying next tier." 'WARN'
            }
        } catch {
            Write-Log "  Direct Node.js MSI failed: $_ — trying next tier." 'WARN'
        }
    }

    # Tier 2 — nvm install lts (nvm is machine-wide via C:\ProgramData\nvm)
    if (-not $nodeOk -and $nvmExe) {
        Write-Log '  Installing Node.js LTS via nvm…' 'DIAG'
        & $nvmExe install lts 2>&1 | ForEach-Object { Write-Log "    [nvm] $_" 'DIAG' }
        & $nvmExe use lts     2>&1 | ForEach-Object { Write-Log "    [nvm] $_" 'DIAG' }
        Update-SessionPath
        # nvm symlink is NVM_SYMLINK (C:\Program Files\nodejs) — set by Install-ClaudeCode above
        $nvmNodePath = [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')
        if ($nvmNodePath -and (Test-Path (Join-Path $nvmNodePath 'node.exe'))) {
            if ($env:Path -notlike "*$nvmNodePath*") { $env:Path = "$env:Path;$nvmNodePath" }
            $nodeOk = $true
            $nodeVer = try { & (Join-Path $nvmNodePath 'node.exe') --version 2>&1 } catch { 'unknown' }
            Write-Log "  Node.js installed via nvm: $nodeVer" 'OK'
        } elseif (Get-Command node -ErrorAction SilentlyContinue) {
            $nodeOk = $true
            Write-Log "  Node.js installed via nvm: $(& node --version 2>&1)" 'OK'
        } else {
            Write-Log '  nvm install did not produce a usable node — trying next tier.' 'WARN'
        }
    }

    # Tier 3 — Chocolatey nodejs-lts
    if (-not $nodeOk) {
        Write-Log '  Trying Chocolatey nodejs-lts…' 'WARN'
        if (Ensure-Chocolatey) {
            $out = & choco upgrade nodejs-lts --yes --no-progress 2>&1
            $raw = ($out -join "`n")
            if ($LASTEXITCODE -eq 0 -or $raw -match '(?i)already installed|is the latest version') {
                Write-Log '  Chocolatey nodejs-lts OK.' 'OK'
                Update-SessionPath
                $chocoNodeDir = @('C:\tools\nodejs', 'C:\ProgramData\chocolatey\bin') |
                    Where-Object { Test-Path (Join-Path $_ 'node.exe') } | Select-Object -First 1
                if (Get-Command node -ErrorAction SilentlyContinue) {
                    $nodeOk = $true
                    Write-Log "  Node.js installed via Chocolatey: $(& node --version 2>&1)" 'OK'
                } elseif ($chocoNodeDir) {
                    if ($env:Path -notlike "*$chocoNodeDir*") { $env:Path = "$env:Path;$chocoNodeDir" }
                    $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
                    if ($mp -notlike "*$chocoNodeDir*") {
                        [System.Environment]::SetEnvironmentVariable('Path', "$mp;$chocoNodeDir", 'Machine')
                    }
                    $nodeOk = $true
                    $nodeVer = try { & (Join-Path $chocoNodeDir 'node.exe') --version 2>&1 } catch { 'unknown' }
                    Write-Log "  Node.js found via Chocolatey path probe: $nodeVer" 'OK'
                }
            } else {
                Write-Log "  Chocolatey nodejs-lts failed (exit $LASTEXITCODE): $raw" 'WARN'
            }
        }
    }

    if (-not $nodeOk) {
        $msg = 'Node.js unavailable after all install attempts — cannot install Claude Code.'
        Write-Log $msg 'FAIL'
        $Manifest.Errors.Add($msg)
        return
    }

    # ── Remove broken winget Claude stub unconditionally ─────────────────────
    # The Anthropic.ClaudeCode winget package creates a stub exe that throws
    # "No application associated" on launch.  Remove it before npm install so
    # it cannot shadow the npm-installed binary on PATH.  Do this regardless of
    # whether Get-Command finds claude — the stub itself satisfies Get-Command.
    $wingetStub = 'C:\Program Files\WinGet\Links\claude.exe'
    if (Test-Path $wingetStub) {
        Write-Log '  Removing broken winget Claude stub before npm install…' 'DIAG'
        & winget uninstall --id Anthropic.ClaudeCode --silent 2>&1 | Out-Null
        if (Test-Path $wingetStub) { Remove-Item $wingetStub -Force -ErrorAction SilentlyContinue }
    }

    # ── Install Claude Code via npm ───────────────────────────────────────────
    $entry = [ordered]@{
        Name      = 'Claude Code'
        Timestamp = (Get-Date -Format 'o')
        Method    = 'npm'
        WingetId  = $null
        ChocoId   = $null
        NpmPkg    = '@anthropic-ai/claude-code'
        Success   = $false
    }

    # Always install to a fixed machine-wide prefix so claude lands in the same
    # place whether this script runs as SYSTEM (NinjaOne) or as an interactive
    # admin.  A user-roaming npm prefix in machine PATH is fragile and breaks
    # for other users whose sessions predate the PATH update.
    $claudeNpmPrefix = 'C:\ProgramData\npm'
    if (-not (Test-Path $claudeNpmPrefix)) {
        New-Item -ItemType Directory -Path $claudeNpmPrefix -Force | Out-Null
        Write-Log "  Created machine-wide npm prefix: $claudeNpmPrefix" 'DIAG'
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $action = if (Test-Path (Join-Path $claudeNpmPrefix 'claude.cmd')) { 'Upgrading' } else { 'Installing' }
        Write-Log "  $action Claude Code via npm (attempt $i)…" 'DIAG'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $out = & npm install -g '--prefix' $claudeNpmPrefix '@anthropic-ai/claude-code' --loglevel=error 2>&1
        $ErrorActionPreference = $prevEap
        if ($LASTEXITCODE -eq 0) {
            if ($env:Path -notlike "*$claudeNpmPrefix*") { $env:Path = "$env:Path;$claudeNpmPrefix" }
            Update-SessionPath
            $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
            $ver = if ($claudeCmd) { (& claude --version 2>&1) -join '' } else { 'installed (PATH refresh required)' }
            Write-Log "  Claude Code installed/updated ($ver)." 'OK'
            $entry.Success = $true
            break
        }
        $raw = ($out -join "`n")
        Write-Log "  npm error (attempt $i): $raw" 'WARN'
        if ($raw -match '(?i)ECONNRESET|ETIMEDOUT|network') { Start-Sleep -Seconds 15 }
        elseif ($i -lt $MaxRetries) { Start-Sleep -Seconds 5 }
    }

    # ── Add machine-wide claude prefix to machine PATH ────────────────────────
    if ($entry.Success) {
        $mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($mp -notlike "*$claudeNpmPrefix*") {
            [System.Environment]::SetEnvironmentVariable('Path', "$mp;$claudeNpmPrefix", 'Machine')
            Write-Log "  Claude global bin added to machine PATH: $claudeNpmPrefix" 'OK'
            $env:Path = "$env:Path;$claudeNpmPrefix"
        } else {
            Write-Log "  Claude global bin already in machine PATH: $claudeNpmPrefix" 'DIAG'
        }
    }

    if (-not $entry.Success) {
        $msg = 'FAILED to install Claude Code.'
        Write-Log $msg 'FAIL'
        $Manifest.Errors.Add($msg)
    }

    $Manifest.Packages.Add($entry)
    Save-Manifest
}

# ─────────────────────────────────────────────────────────────────────────────
# Chatbot deployment — copies files, runs npm install, stores API key
# ─────────────────────────────────────────────────────────────────────────────
function Deploy-SetupChatbot {
    Write-Log '=== Deploying Setup Guide Chatbot ===' 'INFO'

    $chatbotSrc  = Join-Path $PSScriptRoot '..\chatbot'
    $chatbotDest = Join-Path $SetupDir 'chatbot'
    $launcherSrc = Join-Path $PSScriptRoot '..\chatbot\Start-DevSetupGuide.cmd'

    # Copy chatbot source to persistent setup directory
    if (Test-Path $chatbotSrc) {
        if (-not (Test-Path $chatbotDest)) { New-Item -ItemType Directory $chatbotDest -Force | Out-Null }
        Copy-Item "$chatbotSrc\*" $chatbotDest -Recurse -Force
        Write-Log "Chatbot files copied to $chatbotDest" 'DIAG'
    } else {
        Write-Log 'Chatbot source directory not found alongside installer — skipping chatbot deploy.' 'WARN'
        return
    }

    # Run npm install so all dependencies are ready before any user runs the chatbot
    Update-SessionPath
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Log '  Running npm install for chatbot…' 'DIAG'
        Push-Location $chatbotDest
        try {
            # --loglevel=error suppresses npm notices that go to stderr.
            # SilentlyContinue prevents PS5.1 from treating stderr as a terminating error.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $out = & npm install --no-fund --no-audit --loglevel=error 2>&1
            $ErrorActionPreference = $prevEap
            if ($LASTEXITCODE -eq 0) {
                Write-Log '  Chatbot dependencies installed.' 'OK'
            } else {
                Write-Log "  npm install warning (exit $LASTEXITCODE): $($out -join ' ')" 'WARN'
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Log '  npm not available — chatbot dependencies will be installed on first run.' 'WARN'
    }

    # Store Anthropic API key as a machine-level environment variable
    # so every user account on this machine can run the chatbot without
    # any additional configuration.
    if ($AnthropicApiKey -and $AnthropicApiKey -ne '') {
        [System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $AnthropicApiKey, 'Machine')
        $env:ANTHROPIC_API_KEY = $AnthropicApiKey
        Write-Log 'ANTHROPIC_API_KEY stored as machine-level environment variable.' 'OK'
    } else {
        Write-Log 'No -AnthropicApiKey provided. Set ANTHROPIC_API_KEY manually before running the chatbot.' 'WARN'
    }

    Write-Log 'Chatbot deployment complete.' 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
# Multi-user: enumerate real human profiles
# ─────────────────────────────────────────────────────────────────────────────
function Get-HumanUserProfiles {
    $skip = @('systemprofile','LocalService','NetworkService','defaultuser0','Default','All Users','Public')
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin $skip -and
            (Test-Path (Join-Path $_.FullName 'NTUSER.DAT'))
        } |
        Select-Object -ExpandProperty FullName
}

# ─────────────────────────────────────────────────────────────────────────────
# Multi-user: configure existing profiles from SYSTEM context
# ─────────────────────────────────────────────────────────────────────────────
function Configure-ExistingProfiles {
    if (-not (Test-Path $ConfigScript)) {
        Write-Log 'Configure-UserEnvironment.ps1 not found — skipping profile configuration.' 'WARN'
        return
    }

    $profiles = Get-HumanUserProfiles
    if (-not $profiles) {
        Write-Log 'No existing human user profiles found.' 'DIAG'
        return
    }

    foreach ($prof in $profiles) {
        $uname = Split-Path $prof -Leaf
        Write-Log "Configuring existing profile: $uname ($prof)" 'INFO'
        try {
            # Run Configure script targeting this profile path.
            # Extensions are installed via --user-data-dir so they land in the correct
            # user directory even though this process runs as SYSTEM.
            & powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass `
                -File $ConfigScript `
                -UserProfile $prof `
                -SetupDir $SetupDir `
                2>&1 | ForEach-Object { Write-Log "  [$uname] $_" 'DIAG' }
        } catch {
            Write-Log "  Failed to configure ${uname}: $_" 'WARN'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Verification report — quick health check written at end of install
# ─────────────────────────────────────────────────────────────────────────────
function Show-VerificationReport {
    $verifyLog = Join-Path (Split-Path $SetupDir -Parent) 'verify-install.log'
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Refresh PATH one final time so newly installed tools are findable
    Update-SessionPath

    $checks = @(
        @{ Label = 'Git';          Cmd = 'git';       Args = @('--version') }
        @{ Label = 'VS Code';      Cmd = 'code';      Args = @('--version') }
        @{ Label = 'PowerShell 7'; Cmd = 'pwsh';      Args = @('--version') }
        @{ Label = 'nvm';          Cmd = 'nvm';       Args = @('--version') }
        @{ Label = 'Node.js';      Cmd = 'node';      Args = @('--version') }
        @{ Label = 'npm';          Cmd = 'npm';       Args = @('--version') }
        @{ Label = 'Claude Code';  Cmd = 'claude';    Args = @('--version') }
        @{ Label = 'GitHub CLI';   Cmd = 'gh';        Args = @('--version') }
        @{ Label = 'Docker';       Cmd = 'docker';    Args = @('--version') }
        @{ Label = 'Python';       Cmd = 'python';    Args = @('--version')
           # Fallback paths for SYSTEM sessions where Python's PATH isn't refreshed yet
           FallbackExes = @(
               'C:\Program Files\Python312\python.exe',
               'C:\Program Files\Python313\python.exe',
               'C:\Python312\python.exe',
               'C:\Python3\python.exe',
               'C:\ProgramData\chocolatey\bin\python.exe'
           )
        }
        @{ Label = 'AWS CLI';      Cmd = 'aws';       Args = @('--version') }
        @{ Label = 'Terraform';    Cmd = 'terraform'; Args = @('--version') }
    )

    $lines  = @("=== INSTALLATION VERIFICATION  $ts ===")
    $pass   = 0
    $fail   = 0

    Write-Log '' 'INFO'
    Write-Log ('─' * 64) 'INFO'
    Write-Log '  TOOL VERIFICATION' 'INFO'
    Write-Log ('─' * 64) 'INFO'

    foreach ($c in $checks) {
        $exe = Get-Command $c.Cmd -ErrorAction SilentlyContinue
        # For tools with fallback paths, also check known install locations when
        # Get-Command misses them (e.g. Python in a new SYSTEM session before PATH refresh)
        if (-not $exe -and $c.ContainsKey('FallbackExes') -and $c['FallbackExes']) {
            $fb = $c.FallbackExes | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($fb) { $exe = $fb }
        }
        if ($exe) {
            # .Source may not exist on all CommandInfo subtypes (functions, aliases);
            # guard here so a bad node.exe state can't crash the whole verification.
            $exeCmd = try {
                if ($exe -is [string]) { $exe } else { $exe.Source }
            } catch { $null }
            if (-not $exeCmd) {
                $row = "  {0,-15} OK   (path unresolvable)" -f $c.Label
                Write-Log $row 'WARN'
                $lines += $row
                $pass++
                continue
            }
            # Run version check in a background job with an 8-second timeout.
            # Some CLI wrappers (e.g. VS Code's code.cmd) hang indefinitely under
            # SYSTEM context waiting for a UI/server connection.
            $ver = try {
                $job = Start-Job -ScriptBlock {
                    param($exe, $arg)
                    & $exe $arg 2>&1 | Select-Object -First 1
                } -ArgumentList $exeCmd, $c.Args[0]
                if ($job | Wait-Job -Timeout 8) {
                    $out = Receive-Job $job
                    Remove-Job $job -ErrorAction SilentlyContinue
                    ($out | Select-Object -First 1) -replace '\s+$',''
                } else {
                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                    'installed (version check timed out)'
                }
            } catch { 'installed (check error)' }
            $row = "  {0,-15} OK   {1}" -f $c.Label, $ver
            Write-Log $row 'OK'
            $lines += $row
            $pass++
        } else {
            $row = "  {0,-15} NOT FOUND" -f $c.Label
            Write-Log $row 'WARN'
            $lines += $row
            $fail++
        }
    }

    $lines += "  ─────────────────────────────────────────────────────"
    $lines += "  Pass: $pass   Fail/missing: $fail"
    $lines += "=== END ==="
    $lines | Set-Content $verifyLog -Encoding UTF8
    Write-Log ('─' * 64) 'INFO'
    Write-Log "Verification report saved: $verifyLog" 'INFO'
}

# ─────────────────────────────────────────────────────────────────────────────
# Multi-user: register logon task for future accounts
# ─────────────────────────────────────────────────────────────────────────────
function Register-LogonTask {
    Write-Log 'Registering per-user logon configuration task…' 'INFO'

    # Prefer PowerShell 7 if available
    $ps7  = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $psExe = if (Test-Path $ps7) { $ps7 } else { 'powershell.exe' }

    $scriptArg = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ConfigScript`" -SetupDir `"$SetupDir`""

    $action   = New-ScheduledTaskAction -Execute $psExe -Argument $scriptArg
    $trigger  = New-ScheduledTaskTrigger -AtLogOn   # fires for every user logon
    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
                    -MultipleInstances IgnoreNew

    # Run as the interactive user (BUILTIN\Users) — this gives the task the correct
    # user context so it writes to the right HKCU and %USERPROFILE%
    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited

    # Remove stale task registration before re-registering
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Description 'Configures Master Electronics developer tools for each user on first logon.' `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Force | Out-Null

    Write-Log "Logon task '$TaskName' registered." 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $SetupDir)) {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
}

Write-Log ('=' * 64) 'INFO'
Write-Log '  Master Electronics — Developer Environment Installer' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log "Role: $Role  |  MaxRetries: $MaxRetries" 'INFO'
Write-Log "Log : $LogPath" 'INFO'

# Enforce TLS 1.2/1.3 for all web requests
Set-TlsPolicy

# Copy Configure-UserEnvironment.ps1 to the persistent setup directory
$localConfig = Join-Path $PSScriptRoot 'Configure-UserEnvironment.ps1'
if (Test-Path $localConfig) {
    Copy-Item $localConfig $ConfigScript -Force
    Write-Log "Configure-UserEnvironment.ps1 copied to $SetupDir" 'DIAG'
} else {
    Write-Log 'WARNING: Configure-UserEnvironment.ps1 not found alongside installer.' 'WARN'
}

# Save VS Code extension list for per-user configure script
$VsCodeExtensions | ConvertTo-Json | Set-Content $ExtListFile -Encoding UTF8

# Ensure winget is healthy before starting package loop.
# Skip in SYSTEM context — winget is unreliable there and Chocolatey is Tier 1.
if ($RunningAsSystem) {
    Write-Log 'Running as SYSTEM — skipping winget pre-flight (Choco → Direct → winget).' 'DIAG'
} else {
    Ensure-Winget | Out-Null
    Repair-WingetSources
}

# ── Install packages ──────────────────────────────────────────────────────────
foreach ($pkg in $Packages) {
    Install-Package $pkg
    # Refresh PATH after each install so subsequent packages see newly added tools
    Update-SessionPath
}

# ── Claude Code (needs Node, so goes after nvm-windows) ──────────────────────
Install-ClaudeCode

# ── Deploy setup guide chatbot ────────────────────────────────────────────────
Deploy-SetupChatbot

# ── Configure existing user profiles ─────────────────────────────────────────
Configure-ExistingProfiles

# ── Register logon task for future users ─────────────────────────────────────
Register-LogonTask

# ── Verification report ───────────────────────────────────────────────────────
try { Show-VerificationReport } catch { Write-Log "Verification report error: $_" 'WARN' }

# ── Final summary ─────────────────────────────────────────────────────────────
$Manifest.EndTime = (Get-Date -Format 'o')
Save-Manifest

$failCount = $Manifest.Errors.Count

Write-Log '' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log '  INSTALLATION COMPLETE' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log "Packages attempted : $($Manifest.Packages.Count)" 'INFO'
Write-Log "Failures           : $failCount" $(if ($failCount -gt 0) { 'FAIL' } else { 'OK' })

if ($failCount -gt 0) {
    Write-Log '' 'INFO'
    Write-Log 'Failed items:' 'FAIL'
    foreach ($e in $Manifest.Errors) { Write-Log "  * $e" 'FAIL' }
    Write-Log '' 'INFO'
    Write-Log "Full log: $LogPath" 'INFO'
    exit 1
}

Write-Log "Full log: $LogPath" 'INFO'
exit 0




















