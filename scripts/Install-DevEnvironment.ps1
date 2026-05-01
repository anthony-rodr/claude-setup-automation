#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Silent developer environment installer for Master Electronics.

.DESCRIPTION
    Full developer environment deployment script intended to run from NinjaOne as SYSTEM.

    Key behaviors:
    - Installs required tools using bundled installers, direct downloads, Chocolatey, then winget fallback.
    - Avoids bulk Chocolatey install because it can hang under SYSTEM.
    - Uses a stable ProgramData temp directory instead of SYSTEM profile temp.
    - Sets execution policy to RemoteSigned so npm PowerShell shims such as claude.ps1 work.
    - Installs nvm-windows machine-wide as a required dependency.
    - Installs Node.js through nvm.
    - Installs Claude Code machine-wide via npm prefix C:\ProgramData\npm.
    - Configures existing user profiles using Configure-UserEnvironment.ps1.
    - Registers a logon scheduled task for future users.
    - Writes manifest.json for rollback.
    - Writes install and verification logs.

.NOTES
    Expected package layout when launched from the release zip:

        package\
          scripts\
            Install-DevEnvironment.ps1
            Configure-UserEnvironment.ps1
            packages.config
          bundled\
            ME_Git_for_Windows.exe
            ME_Visual_Studio_Code.exe
            ME_Python_3_12.exe
            ME_GitHub_CLI.msi
            ME_AWS_CLI_v2.msi
            ME_Terraform.zip

    The setup guide chatbot has been removed from this installer.
#>

[CmdletBinding()]
param(
    [ValidateSet('Core', 'Dev', 'CloudOps', 'All')]
    [string]$Role = 'All',

    [int]$MaxRetries = 3,

    [string]$LogPath = 'C:\ProgramData\MasterElectronics\DevSetup\install.log',

    [string]$ManifestPath = 'C:\ProgramData\MasterElectronics\DevSetup\manifest.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$SetupDir     = Split-Path $ManifestPath -Parent
$ConfigScript = Join-Path $SetupDir 'Configure-UserEnvironment.ps1'
$ExtListFile  = Join-Path $SetupDir 'vscode-extensions.json'
$TaskName     = 'MasterElectronics-ConfigureUserEnvironment'
$TempDir      = Join-Path $SetupDir 'Temp'

$NvmHome      = 'C:\ProgramData\nvm'
$NvmSymlink   = 'C:\Program Files\nodejs'
$NpmPrefix    = 'C:\ProgramData\npm'

$RunningAsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -match 'SYSTEM'

foreach ($dir in @($SetupDir, $TempDir, (Split-Path $LogPath -Parent))) {
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Msg,
        [ValidateSet('INFO','OK','WARN','FAIL','DIAG')]
        [string]$Level = 'INFO'
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"

    # Retry on file lock — a surviving process from a prior run can briefly
    # hold the log file. A transient lock must not crash the installer.
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 300 }
    }

    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'DIAG' { 'Cyan' }
        default { 'White' }
    }

    Write-Host $line -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------
function Set-TlsPolicy {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function Update-SessionPath {
    foreach ($scope in @('Machine','User')) {
        try {
            $vars = [System.Environment]::GetEnvironmentVariables($scope)
            foreach ($key in $vars.Keys) {
                if ($key -ne 'Path') {
                    Set-Item -Path "Env:\$key" -Value $vars[$key] -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }

    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    if (-not $machinePath) { $machinePath = '' }
    if (-not $userPath)    { $userPath = '' }

    $env:Path = ([System.Environment]::ExpandEnvironmentVariables($machinePath) + ';' +
                 [System.Environment]::ExpandEnvironmentVariables($userPath)).TrimEnd(';')
}

function Add-MachinePath {
    param([Parameter(Mandatory)][string]$PathToAdd)

    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not $machinePath) { $machinePath = '' }

    $segments = $machinePath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
    $exists = $false

    foreach ($segment in $segments) {
        if ($segment.TrimEnd('\') -ieq $PathToAdd.TrimEnd('\')) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newPath = ($segments + $PathToAdd) -join ';'
        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        Write-Log "Added to machine PATH: $PathToAdd" 'OK'
    }

    if ($env:Path -notlike "*$PathToAdd*") {
        $env:Path = "$env:Path;$PathToAdd"
    }

    Update-SessionPath
}

function Set-RequiredExecutionPolicy {
    try {
        Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
        Write-Log 'PowerShell execution policy set to RemoteSigned.' 'OK'
    } catch {
        Write-Log "Could not set execution policy to RemoteSigned: $_" 'WARN'
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest
    )

    $destDir = Split-Path $Dest -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        if (Test-Path $Dest) {
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
        }

        try {
            Invoke-WebRequest $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
            if (-not (Test-Path $Dest)) {
                throw "Downloaded file missing: $Dest"
            }
            return
        } catch {
            if ($i -eq $MaxRetries) {
                throw
            }

            Write-Log "Download attempt $i failed ($Url). Retrying in 10 seconds." 'WARN'
            Start-Sleep -Seconds 10
        }
    }
}

function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 1800,
        [string]$Label = ''
    )

    $stdout = Join-Path $TempDir ("proc_out_{0}_{1}.txt" -f $PID, ([guid]::NewGuid().ToString('N')))
    $stderr = Join-Path $TempDir ("proc_err_{0}_{1}.txt" -f $PID, ([guid]::NewGuid().ToString('N')))

    $p = Start-Process -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru `
        -NoNewWindow

    $done = $p.WaitForExit($TimeoutSeconds * 1000)

    # WaitForExit(ms) does not guarantee ExitCode is populated on PS 5.1.
    # Calling WaitForExit() (no arg) after a successful timed wait flushes
    # pending events and ensures ExitCode is set.
    if ($done) { $p.WaitForExit() }

    if (-not $done) {
        try { $p.Kill() } catch { }
        Write-Log "Process timed out after $TimeoutSeconds seconds: $FilePath $($ArgumentList -join ' ')" 'WARN'
        return [pscustomobject]@{
            ExitCode = -1
            Output   = ''
            TimedOut = $true
        }
    }

    $out = ''
    if (Test-Path $stdout) {
        $out += (Get-Content $stdout -Raw -ErrorAction SilentlyContinue)
    }
    if (Test-Path $stderr) {
        $err = Get-Content $stderr -Raw -ErrorAction SilentlyContinue
        if ($err) { $out += "`n$err" }
    }

    Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue

    if ($Label -and $out) {
        $out -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object {
            Write-Log "  [$Label] $_" 'DIAG'
        }
    }

    # $p.ExitCode can be null on PS 5.1 even after WaitForExit() for certain EXEs
    # (launchers that spawn child processes). Treat null as 0 (success), matching
    # the same pattern used in NinjaOne-Bootstrap.ps1.
    $exitCode = $p.ExitCode
    if ($null -eq $exitCode) {
        Write-Log "  Invoke-Process: null exit code after process exit — treating as 0." 'WARN'
        $exitCode = 0
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $out
        TimedOut = $false
    }
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$FallbackExes = @()
    )

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($fb in $FallbackExes) {
        if ($fb -and (Test-Path $fb)) { return $fb }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
$Manifest = [ordered]@{
    SchemaVersion = '1.1'
    StartTime     = (Get-Date -Format 'o')
    Role          = $Role
    Packages      = [System.Collections.Generic.List[object]]::new()
    ChocolateyInstalled = $false
    Errors        = [System.Collections.Generic.List[string]]::new()
    Warnings      = [System.Collections.Generic.List[string]]::new()
}

function Save-Manifest {
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content $ManifestPath -Encoding UTF8
}

function Add-InstallWarning {
    param([string]$Message)
    Write-Log $Message 'WARN'
    $Manifest.Warnings.Add($Message)
    Save-Manifest
}

function Add-InstallError {
    param([string]$Message)
    Write-Log $Message 'FAIL'
    $Manifest.Errors.Add($Message)
    Save-Manifest
}

function Send-UserNotification {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$TimeoutSeconds = 120
    )

    try {
        & "$env:SystemRoot\System32\msg.exe" * /TIME:$TimeoutSeconds $Message 2>&1 | Out-Null
        Write-Log "User notification sent: $Message" 'OK'
    } catch {
        Write-Log "Could not send user notification: $_" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Package catalog
# ---------------------------------------------------------------------------
$Packages = @(
    @{
        Name      = 'Git for Windows'
        Roles     = @('Core','Dev','CloudOps','All')
        Winget    = 'Git.Git'
        Choco     = 'git'
        VerifyCmd = 'git'
        Direct    = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
            ($r.assets | Where-Object { $_.name -match '-64-bit\.exe$' } | Select-Object -First 1).browser_download_url
        }
        DArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"'
        DType     = 'exe'
    }
    @{
        Name      = 'Visual Studio Code'
        Roles     = @('Core','Dev','CloudOps','All')
        Winget    = 'Microsoft.VisualStudioCode'
        Choco     = 'vscode'
        VerifyCmd = 'code'
        VerifyExe = 'C:\Program Files\Microsoft VS Code\Code.exe'
        Direct    = { 'https://update.code.visualstudio.com/latest/win32-x64/stable' }
        DArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'
        DType     = 'exe'
    }
    @{
        Name      = 'PowerShell 7'
        Roles     = @('Core','Dev','CloudOps','All')
        Winget    = 'Microsoft.PowerShell'
        Choco     = 'powershell-core'
        VerifyCmd = 'pwsh'
        VerifyExe = 'C:\Program Files\PowerShell\7\pwsh.exe'
        FallbackExes = @('C:\Program Files\PowerShell\7\pwsh.exe')
        Direct    = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            ($r.assets | Where-Object { $_.name -match 'win-x64\.msi$' -and $_.name -notmatch 'preview' } | Select-Object -First 1).browser_download_url
        }
        DArgs     = '/quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1'
        DType     = 'msi'
    }
    @{
        Name      = 'nvm-windows'
        Roles     = @('Dev','All')
        Winget    = $null
        Choco     = $null
        VerifyCmd = 'nvm'
        VerifyExe = 'C:\ProgramData\nvm\nvm.exe'
        Direct    = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/coreybutler/nvm-windows/releases/latest'
            ($r.assets | Where-Object { $_.name -eq 'nvm-noinstall.zip' } | Select-Object -First 1).browser_download_url
        }
        DType     = 'zip-to-path'
        ZipDest   = 'C:\ProgramData\nvm'
    }
    @{
        Name      = 'Python 3.12'
        Roles     = @('Dev','All')
        Winget    = 'Python.Python.3.12'
        Choco     = 'python312'
        VerifyCmd = 'python'
        VerifyExe = 'C:\Program Files\Python312\python.exe'
        FallbackExes = @(
            'C:\Program Files\Python312\python.exe',
            'C:\Program Files\Python313\python.exe',
            'C:\Python312\python.exe',
            'C:\Python3\python.exe'
        )
        Direct    = {
            try {
                $releases = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
                $rel = $releases | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } | Select-Object -First 1
                $asset = $rel.assets | Where-Object { $_.name -match 'amd64\.exe$' } | Select-Object -First 1
                if ($asset) { return $asset.browser_download_url }
            } catch { }
            'https://www.python.org/ftp/python/3.12.9/python-3.12.9-amd64.exe'
        }
        DArgs     = '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0'
        DType     = 'exe'
        AltPaths  = @(
            'C:\Program Files\Python312',
            'C:\Program Files\Python313',
            'C:\Program Files\Python311',
            'C:\Python312',
            'C:\Python3'
        )
        PreInstall = {
            # Python's EXE bootstrapper exits immediately (error 1618) if Windows
            # Installer is already busy. Previous bundled installers (Git, VS Code,
            # PS7) spawn background msiexec processes that may still be running.
            # Wait on the Global\_MSIExecute mutex until the Installer is idle.
            $msiDeadline = (Get-Date).AddSeconds(300)
            $msiLogged   = $false
            while ((Get-Date) -lt $msiDeadline) {
                try {
                    $msiMutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
                    $msiMutex.Dispose()
                    if (-not $msiLogged) {
                        Write-Log '  Waiting for Windows Installer to become idle before Python install...' 'DIAG'
                        $msiLogged = $true
                    }
                    Start-Sleep -Seconds 8
                } catch [System.Threading.WaitHandleCannotBeOpenedException] {
                    break  # mutex gone — Installer is idle
                } catch {
                    break  # unexpected; proceed
                }
            }

            # Remove stale Python directories that cause MSI error 1603 on re-install
            # after an incomplete rollback leaves the directory behind.
            foreach ($d in @('C:\Python312','C:\Python313','C:\Program Files\Python312','C:\Program Files\Python313')) {
                if (Test-Path $d) {
                    Write-Log "  Pre-install: removing stale Python directory: $d" 'DIAG'
                    Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    @{
        Name      = 'GitHub CLI'
        Roles     = @('Dev','All')
        Winget    = 'GitHub.cli'
        Choco     = 'gh'
        VerifyCmd = 'gh'
        Direct    = {
            $r = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest'
            ($r.assets | Where-Object { $_.name -match 'windows_amd64\.msi$' } | Select-Object -First 1).browser_download_url
        }
        DArgs     = '/quiet /norestart'
        DType     = 'msi'
    }
    @{
        Name   = 'Windows Subsystem for Linux 2'
        Roles  = @('Dev','All')
        Winget = 'Microsoft.WSL'
        Choco  = $null
        Direct = $null
        DArgs  = '--install --no-distribution'
        DType  = 'wsl-install'
    }
    @{
        Name      = 'Docker Desktop'
        Roles     = @('Dev','All')
        Winget    = 'Docker.DockerDesktop'
        Choco     = 'docker-desktop'
        VerifyCmd = 'docker'
        Direct    = { 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' }
        DArgs     = 'install --quiet --accept-license --backend=wsl-2'
        DType     = 'exe-args'
    }
    @{
        Name      = 'AWS CLI v2'
        Roles     = @('CloudOps','All')
        Winget    = 'Amazon.AWSCLI'
        Choco     = 'awscli'
        VerifyCmd = 'aws'
        Direct    = { 'https://awscli.amazonaws.com/AWSCLIV2.msi' }
        DArgs     = '/quiet /norestart'
        DType     = 'msi'
    }
    @{
        Name      = 'Terraform'
        Roles     = @('CloudOps','All')
        Winget    = 'Hashicorp.Terraform'
        Choco     = 'terraform'
        VerifyCmd = 'terraform'
        Direct    = {
            $cp  = Invoke-RestMethod 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
            $ver = $cp.current_version
            "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip"
        }
        DType     = 'zip-to-path'
        ZipDest   = 'C:\Program Files\Terraform'
    }
    @{
        Name       = 'Claude Desktop'
        Roles      = @('Dev','All')
        Winget     = $null
        Choco      = $null
        Direct     = { 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' }
        DType      = 'msix'
        VerifyAppx = '*Claude*'
    }
)

$VsCodeExtensions = @(
    'ms-vscode.PowerShell',
    'ms-python.python',
    'hashicorp.terraform',
    'amazonwebservices.aws-toolkit-vscode',
    'GitHub.vscode-pull-request-github',
    'eamodio.gitlens',
    'ms-vscode-remote.remote-wsl',
    'esbenp.prettier-vscode',
    'dbaeumer.vscode-eslint',
    'ms-azuretools.vscode-docker'
)

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------
function Repair-WingetSources {
    try {
        Write-Log 'Resetting and refreshing winget sources.' 'DIAG'
        & winget source reset --force 2>&1 | Out-Null
        & winget source update 2>&1 | Out-Null
        Write-Log 'winget sources refreshed.' 'OK'
    } catch {
        Write-Log "winget source refresh warning: $_" 'WARN'
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

    if ($RunningAsSystem) {
        Write-Log 'winget not found under SYSTEM. Skipping winget repair.' 'DIAG'
        return $false
    }

    try {
        $tmp = Join-Path $TempDir 'AppInstaller.msixbundle'
        Invoke-Download 'https://aka.ms/getwinget' $tmp
        Add-AppxPackage -Path $tmp -ForceApplicationShutdown -ErrorAction Stop
        Update-SessionPath
        return (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
    } catch {
        Write-Log "winget repair failed: $_" 'WARN'
        return $false
    }
}

function Install-ViaWinget {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    if (-not $Pkg.Winget) { return $false }
    if (-not (Ensure-Winget)) { return $false }

    $id = $Pkg.Winget

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Log "  winget install/upgrade $id attempt $i." 'DIAG'

        $out = & winget upgrade --id $id --silent --accept-package-agreements --accept-source-agreements --scope machine --disable-interactivity 2>&1
        $raw = $out -join "`n"

        if ($LASTEXITCODE -eq 0 -or $raw -match '(?i)no applicable upgrade|already installed|no available upgrade') {
            Write-Log "  winget OK: $id" 'OK'
            return $true
        }

        if ($raw -match '(?i)No installed package found|not installed|No applicable update') {
            $out = & winget install --id $id --silent --accept-package-agreements --accept-source-agreements --scope machine --disable-interactivity 2>&1
            $raw = $out -join "`n"
            if ($LASTEXITCODE -eq 0 -or $raw -match '(?i)already installed') {
                Write-Log "  winget install OK: $id" 'OK'
                return $true
            }
        }

        if ($raw -match '(?i)No package found') {
            Write-Log "  winget package not found: $id" 'WARN'
            return $false
        }

        if ($raw -match '(?i)source agreements') {
            Repair-WingetSources
        } elseif ($raw -match '(?i)timeout|network|unable to connect|internet') {
            Start-Sleep -Seconds 15
        } elseif ($raw -match '(?i)another installation is in progress|locked|access is denied') {
            Start-Sleep -Seconds 30
        } else {
            Write-Log "  winget failed attempt $i for $id. Exit $LASTEXITCODE. $raw" 'WARN'
            Start-Sleep -Seconds 5
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# Chocolatey
# ---------------------------------------------------------------------------
function Ensure-Chocolatey {
    [OutputType([bool])]
    param()

    if (Get-Command choco -ErrorAction SilentlyContinue) {
        $v = (& choco --version 2>&1 | Select-Object -First 1)
        Write-Log "Chocolatey $v is present." 'DIAG'
        return $true
    }

    try {
        Write-Log 'Installing Chocolatey.' 'DIAG'
        Set-TlsPolicy
        $script = (Invoke-WebRequest 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -ErrorAction Stop).Content
        Invoke-Expression $script
        Update-SessionPath

        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Log 'Chocolatey installed.' 'OK'
            $Manifest.ChocolateyInstalled = $true
            Save-Manifest
            return $true
        }
    } catch {
        Write-Log "Chocolatey install failed: $_" 'WARN'
    }

    return $false
}

function Install-ViaChocolatey {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    if (-not $Pkg.Choco) { return $false }
    if (-not (Ensure-Chocolatey)) { return $false }

    $id = $Pkg.Choco

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Log "  choco upgrade $id attempt $i." 'DIAG'

        $result = Invoke-Process -FilePath 'choco.exe' `
            -ArgumentList @('upgrade', $id, '--yes', '--no-progress') `
            -TimeoutSeconds 900 `
            -Label 'choco'

        $raw = $result.Output

        $pkgAlreadyPresent = $raw -match "(?i)$([regex]::Escape($id)).*(already installed|is the latest version|latest version available)"
        if ($result.ExitCode -eq 0 -or $pkgAlreadyPresent) {
            Write-Log "  choco OK: $id" 'OK'
            Update-SessionPath

            $verifyExe = if ($Pkg.ContainsKey('VerifyExe')) { $Pkg.VerifyExe } else { $null }
            if ($verifyExe -and -not (Test-Path $verifyExe)) {
                Write-Log "  choco reported success but VerifyExe is missing: $verifyExe. Forcing reinstall." 'WARN'
                $force = Invoke-Process -FilePath 'choco.exe' `
                    -ArgumentList @('install', $id, '--yes', '--no-progress', '--force') `
                    -TimeoutSeconds 900 `
                    -Label 'choco-force'
                Update-SessionPath
                if ($force.ExitCode -ne 0 -and -not (Test-Path $verifyExe)) {
                    Write-Log "  Forced Chocolatey install did not create VerifyExe: $verifyExe" 'WARN'
                    return $false
                }
            }

            return $true
        }

        if ($result.TimedOut) {
            Write-Log "  choco timed out for $id." 'WARN'
            return $false
        }

        if ($raw -match '(?i)timeout|network|unable to connect') {
            Start-Sleep -Seconds 15
        } elseif ($raw -match '(?i)locked|access is denied|another installation') {
            Start-Sleep -Seconds 30
        } else {
            Write-Log "  choco failed attempt $i for $id. Exit $($result.ExitCode)." 'WARN'
            Start-Sleep -Seconds 5
        }
    }

    return $false
}

# ---------------------------------------------------------------------------
# Direct installers
# ---------------------------------------------------------------------------
function Get-BundledPath {
    param([hashtable]$Pkg)

    $ext = switch ($Pkg.DType) {
        'msi'         { '.msi' }
        'zip-to-path' { '.zip' }
        'msix'        { '.msix' }
        default       { '.exe' }
    }

    $fileName = "ME_$($Pkg.Name -replace '[^\w]','_')$ext"
    return Join-Path (Join-Path $PSScriptRoot '..\bundled') $fileName
}

function Install-ViaDirectDownload {
    [OutputType([bool])]
    param([hashtable]$Pkg)

    if ($Pkg.DType -eq 'wsl-install') {
        # wsl.exe --install fails under SYSTEM when launched via Start-Process with
        # redirected handles ("The handle is invalid"). Use DISM feature enablement
        # instead, which works reliably as SYSTEM with no console handle required.
        try {
            Write-Log '  Enabling WSL via DISM (Microsoft-Windows-Subsystem-Linux + VirtualMachinePlatform).' 'DIAG'

            $wslResult = Invoke-Process -FilePath "$env:SystemRoot\System32\dism.exe" `
                -ArgumentList @('/online', '/enable-feature', '/featurename:Microsoft-Windows-Subsystem-Linux', '/all', '/norestart') `
                -TimeoutSeconds 600 -Label 'dism-wsl'

            $vmpResult = Invoke-Process -FilePath "$env:SystemRoot\System32\dism.exe" `
                -ArgumentList @('/online', '/enable-feature', '/featurename:VirtualMachinePlatform', '/all', '/norestart') `
                -TimeoutSeconds 600 -Label 'dism-vmp'

            # Invoke-Process may return null ExitCode on some Windows builds even when
            # the process completes successfully. Fall back to output string matching.
            $wslOk = $wslResult.ExitCode -in @(0,3010) -or $wslResult.Output -match '(?i)operation completed successfully'
            $vmpOk = $vmpResult.ExitCode -in @(0,3010) -or $vmpResult.Output -match '(?i)operation completed successfully'

            if ($wslOk -and $vmpOk) {
                Write-Log '  WSL features enabled. Reboot required before WSL can be used.' 'OK'

                # DISM enables the Windows feature but not the WSL2 kernel package.
                # Without the kernel, Windows shows a first-run setup wizard on each
                # login. Register a one-shot startup task as SYSTEM to run
                # wsl --update + wsl --set-default-version 2 after the reboot.
                try {
                    $wslTaskName = 'MasterElectronics-WSLPostReboot'
                    $wslCmd = 'wsl.exe --update --web-download; wsl.exe --set-default-version 2; ' +
                              "Unregister-ScheduledTask -TaskName '$wslTaskName' -Confirm:`$false -ErrorAction SilentlyContinue"
                    $wslAction   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$wslCmd`""
                    $wslTrigger  = New-ScheduledTaskTrigger -AtStartup
                    $wslSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
                    $wslPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    Register-ScheduledTask -TaskName $wslTaskName -Action $wslAction -Trigger $wslTrigger `
                        -Settings $wslSettings -Principal $wslPrincipal -Force | Out-Null
                    Write-Log '  WSL post-reboot kernel task registered (runs once at next startup).' 'OK'
                } catch {
                    Write-Log "  Could not register WSL post-reboot task: $_" 'WARN'
                }

                return $true
            }

            Write-Log "  DISM WSL exit $($wslResult.ExitCode), VirtualMachinePlatform exit $($vmpResult.ExitCode)." 'WARN'
        } catch {
            Write-Log "  WSL DISM feature enablement failed: $_" 'WARN'
        }
        return $false
    }

    if (-not $Pkg.Direct) { return $false }

    $ext = switch ($Pkg.DType) {
        'msi'         { '.msi' }
        'zip-to-path' { '.zip' }
        'msix'        { '.msix' }
        default       { '.exe' }
    }

    $tmpFileName = "ME_$($Pkg.Name -replace '[^\w]','_')$ext"
    $bundledFile = Get-BundledPath $Pkg
    $tmpFile = $null
    $isBundled = $false

    if (Test-Path $bundledFile) {
        $tmpFile = [System.IO.Path]::GetFullPath($bundledFile)
        $isBundled = $true
        Write-Log "  Bundled installer found: $tmpFile" 'OK'
    } else {
        try {
            Write-Log "  Resolving direct URL for $($Pkg.Name)." 'DIAG'
            $url = & $Pkg.Direct
            if (-not $url) { throw 'URL resolved to null.' }

            $tmpFile = Join-Path $TempDir $tmpFileName
            Write-Log "  Downloading: $url" 'DIAG'
            Invoke-Download $url $tmpFile
        } catch {
            Write-Log "  Direct download failed: $_" 'WARN'
            return $false
        }
    }

    try {
        switch ($Pkg.DType) {
            'exe' {
                $args = if ($Pkg.DArgs) { $Pkg.DArgs } else { '' }
                $result = Invoke-Process -FilePath $tmpFile -ArgumentList @($args) -TimeoutSeconds 1800
                if ($result.ExitCode -notin @(0,3010)) {
                    throw "Exit code $($result.ExitCode)"
                }

                if ($Pkg.ContainsKey('AltPaths') -and $Pkg.AltPaths) {
                    $deadline = (Get-Date).AddSeconds(300)
                    $found = $null
                    while (-not $found -and (Get-Date) -lt $deadline) {
                        foreach ($d in $Pkg.AltPaths) {
                            if (Test-Path (Join-Path $d 'python.exe')) {
                                $found = $d
                                break
                            }
                        }
                        if (-not $found) { Start-Sleep -Seconds 5 }
                    }

                    if ($found) {
                        Add-MachinePath $found
                        Add-MachinePath (Join-Path $found 'Scripts')
                    }
                }
            }

            'exe-args' {
                $args = if ($Pkg.DArgs) { $Pkg.DArgs } else { '' }
                $result = Invoke-Process -FilePath $tmpFile -ArgumentList @($args) -TimeoutSeconds 2400
                if ($result.ExitCode -notin @(0,3010)) {
                    throw "Exit code $($result.ExitCode)"
                }
            }

            'msi' {
                $resolved = [System.IO.Path]::GetFullPath($tmpFile)
                $argString = "/i `"$resolved`" $($Pkg.DArgs)"
                $result = Invoke-Process -FilePath 'msiexec.exe' -ArgumentList @($argString) -TimeoutSeconds 1800
                if ($result.ExitCode -notin @(0,3010,1641)) {
                    throw "msiexec exit $($result.ExitCode)"
                }
            }

            'msix' {
                Add-AppxProvisionedPackage -Online -PackagePath $tmpFile -SkipLicense -ErrorAction Stop | Out-Null
            }

            'zip-to-path' {
                $dest = if ($Pkg.ContainsKey('ZipDest') -and $Pkg.ZipDest) { $Pkg.ZipDest } else { 'C:\Program Files\ZipInstall' }
                if (-not (Test-Path $dest)) {
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null
                }
                Expand-Archive -Path $tmpFile -DestinationPath $dest -Force
                Add-MachinePath $dest

                if ($Pkg.Name -eq 'nvm-windows') {
                    Configure-NvmEnvironment -NvmDir $dest
                }
            }

            default {
                throw "Unsupported DType: $($Pkg.DType)"
            }
        }

        Update-SessionPath
        Write-Log "  Direct install OK: $($Pkg.Name)" 'OK'
        return $true
    } catch {
        Write-Log "  Direct install error: $_" 'WARN'
        return $false
    } finally {
        if (-not $isBundled -and $tmpFile -and (Test-Path $tmpFile)) {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# nvm / Node
# ---------------------------------------------------------------------------
function Configure-NvmEnvironment {
    param([Parameter(Mandatory)][string]$NvmDir)

    if (-not (Test-Path $NvmDir)) {
        New-Item -ItemType Directory -Path $NvmDir -Force | Out-Null
    }

    [System.Environment]::SetEnvironmentVariable('NVM_HOME', $NvmDir, 'Machine')
    [System.Environment]::SetEnvironmentVariable('NVM_SYMLINK', $NvmSymlink, 'Machine')

    $env:NVM_HOME = $NvmDir
    $env:NVM_SYMLINK = $NvmSymlink

    Add-MachinePath $NvmDir
    Add-MachinePath $NvmSymlink

    $settingsFile = Join-Path $NvmDir 'settings.txt'
    @"
root: $NvmDir
path: $NvmSymlink
arch: 64
proxy: none
"@ | Set-Content $settingsFile -Encoding UTF8

    Write-Log "nvm settings written: $settingsFile" 'OK'
    Update-SessionPath
}

function Install-NodeFromBundle {
    [OutputType([bool])]
    param()

    $bundledZip = Join-Path (Join-Path $PSScriptRoot '..\bundled') 'ME_Node_LTS.zip'
    if (-not (Test-Path $bundledZip)) {
        Write-Log 'ME_Node_LTS.zip not found in bundled/. Cannot fall back to bundled Node.' 'WARN'
        return $false
    }

    $extractTemp = Join-Path $TempDir 'node-extract'
    if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null

    Expand-Archive -Path $bundledZip -DestinationPath $extractTemp -Force

    $nodeDir = Get-ChildItem $extractTemp -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeDir -or -not (Test-Path (Join-Path $nodeDir.FullName 'node.exe'))) {
        Write-Log 'Could not find node.exe inside ME_Node_LTS.zip.' 'WARN'
        return $false
    }

    if ($nodeDir.Name -notmatch 'node-(v[\d.]+)-win') {
        Write-Log "Could not parse Node version from directory name: $($nodeDir.Name)" 'WARN'
        return $false
    }
    $nodeVersion = $Matches[1]
    $versionDir = Join-Path $NvmHome $nodeVersion

    if (Test-Path $versionDir) {
        Remove-Item $versionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Move-Item $nodeDir.FullName $versionDir
    Remove-Item $extractTemp -Force -ErrorAction SilentlyContinue

    Write-Log "Node $nodeVersion extracted from bundle to $versionDir" 'OK'
    return $true
}

function Repair-NodeSymlink {
    $installedNode = Get-ChildItem $NvmHome -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'node.exe') } |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $installedNode) {
        Add-InstallError "Node was not found inside $NvmHome after nvm install."
        return $false
    }

    if (Test-Path $NvmSymlink) {
        Remove-Item $NvmSymlink -Recurse -Force -ErrorAction SilentlyContinue
    }

    cmd.exe /c "mklink /J `"$NvmSymlink`" `"$($installedNode.FullName)`"" | Out-Null

    if (-not (Test-Path (Join-Path $NvmSymlink 'node.exe'))) {
        Add-InstallError "Failed to create Node junction from $NvmSymlink to $($installedNode.FullName)."
        return $false
    }

    Write-Log "Node junction repaired: $NvmSymlink -> $($installedNode.FullName)" 'OK'
    return $true
}

function Test-NvmRequired {
    $nvmExe = Join-Path $NvmHome 'nvm.exe'
    if (-not (Test-Path $nvmExe)) {
        return $false
    }

    Configure-NvmEnvironment -NvmDir $NvmHome

    $out = & $nvmExe version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "nvm.exe exists but failed to run: $($out -join ' ')" 'WARN'
        return $false
    }

    Write-Log "nvm verified: $($out | Select-Object -First 1)" 'OK'
    return $true
}

function Install-NodeThroughNvm {
    $nvmExe = Join-Path $NvmHome 'nvm.exe'

    if (-not (Test-NvmRequired)) {
        Add-InstallError 'nvm-windows is required but is not installed or not functional. Cannot install Node/Claude stack.'
        return $false
    }

    Write-Log 'Installing Node.js LTS via nvm.' 'INFO'

    $install = Invoke-Process -FilePath $nvmExe -ArgumentList @('install','lts') -TimeoutSeconds 1200 -Label 'nvm'

    # nvm may exit non-zero if the LTS alias lookup fails (DNS/network), but still
    # successfully install a version. Parse the version from output and continue.
    $nodeVersion = $null
    if ($install.Output -match 'nvm use (\d+\.\d+\.\d+)') {
        $nodeVersion = $Matches[1]
        Write-Log "Parsed installed Node version from nvm output: $nodeVersion" 'DIAG'
    }

    $installSucceeded = $install.ExitCode -eq 0 -or
        ($nodeVersion -and $install.Output -match '(?i)installation complete')

    if (-not $installSucceeded) {
        Add-InstallError "nvm install lts failed. $($install.Output)"
        return $false
    }

    # If the download was interrupted/rolled back, skip nvm use entirely — it would hang
    # trying to look up the 'lts' alias over the blocked network. The $nvmNodePresent
    # check below will detect no node.exe and trigger the bundled Node LTS zip fallback.
    $downloadInterrupted = $install.Output -match '(?i)(download interrupted|installation canceled)'

    if (-not $downloadInterrupted) {
        # If the symlink target exists as a plain directory (not a junction), nvm cannot
        # create the junction over it and will silently report success without placing node.exe.
        # Remove the plain directory so nvm use can create the junction cleanly.
        if (Test-Path $NvmSymlink) {
            $symlinkItem = Get-Item $NvmSymlink -ErrorAction SilentlyContinue
            if ($symlinkItem -and $symlinkItem.LinkType -ne 'Junction') {
                Write-Log "$NvmSymlink exists as a plain directory (not a junction) - removing so nvm can create junction." 'DIAG'
                Remove-Item $NvmSymlink -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Prefer explicit version number over the 'lts' alias - nvm use with an alias
        # can fail silently on machines where the alias lookup also fails.
        $useArg = if ($nodeVersion) { $nodeVersion } else { 'lts' }
        Write-Log "Running: nvm use $useArg" 'DIAG'

        $use = Invoke-Process -FilePath $nvmExe -ArgumentList @('use', $useArg) -TimeoutSeconds 300 -Label 'nvm'
        $useSucceeded = $use.ExitCode -eq 0 -or $use.Output -match '(?i)now using node'
        if (-not $useSucceeded) {
            Add-InstallError "nvm use $useArg failed. $($use.Output)"
            return $false
        }

        Update-SessionPath
        Add-MachinePath $NvmSymlink
    } else {
        Write-Log 'nvm download interrupted — skipping nvm use, falling back to bundled Node.' 'WARN'
    }

    # Verify nvm actually downloaded node. nvm can print "Installation complete" and
    # "Now using node vX" without placing any files if nodejs.org is unreachable
    # (e.g. blocked by Zscaler). Fall back to the bundled Node LTS zip in that case.
    $nvmNodePresent = $null -ne (
        Get-ChildItem $NvmHome -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'node.exe') } |
        Select-Object -First 1
    )

    if (-not $nvmNodePresent) {
        Write-Log 'nvm did not download Node.js (likely network blocked). Falling back to bundled ME_Node_LTS.zip.' 'WARN'
        if (-not (Install-NodeFromBundle)) {
            Add-InstallError 'nvm download failed and bundled Node LTS zip fallback also failed. Cannot install Node.'
            return $false
        }
    }

    # Explicitly rebuild the junction after nvm use. nvm silently prints "Now using
    # node" but may not create the junction if $NvmSymlink existed as any kind of
    # directory. Repair-NodeSymlink scans $NvmHome for the actual node.exe and calls
    # mklink /J directly, guaranteeing the junction is correct.
    if (-not (Repair-NodeSymlink)) {
        return $false
    }

    $nodeExe = Join-Path $NvmSymlink 'node.exe'
    $npmCmd  = Join-Path $NvmSymlink 'npm.cmd'

    if (-not (Test-Path $npmCmd)) {
        Add-InstallError "nvm completed but npm.cmd was not found at $npmCmd."
        return $false
    }

    $nodeVer = & $nodeExe --version 2>&1
    $npmVer  = & $npmCmd --version 2>&1

    Write-Log "Node.js installed via nvm: $nodeVer" 'OK'
    Write-Log "npm available via nvm: $npmVer" 'OK'

    return $true
}

# ---------------------------------------------------------------------------
# Package orchestrator
# ---------------------------------------------------------------------------
function Install-Package {
    param([hashtable]$Pkg)

    $inRole = $Role -eq 'All' -or 'All' -in $Pkg.Roles -or $Role -in $Pkg.Roles
    if (-not $inRole) {
        Write-Log "Skip '$($Pkg.Name)' for role '$Role'." 'DIAG'
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

    $verifyCmd = if ($Pkg.ContainsKey('VerifyCmd')) { $Pkg.VerifyCmd } else { $null }
    $fallbacks = if ($Pkg.ContainsKey('FallbackExes')) { $Pkg.FallbackExes } else { @() }
    $verifyExe = if ($Pkg.ContainsKey('VerifyExe')) { $Pkg.VerifyExe } else { $null }

    if ($verifyExe -and (Test-Path $verifyExe)) {
        if ($Pkg.Name -eq 'nvm-windows') {
            if (Test-NvmRequired) {
                Write-Log "  $($Pkg.Name) already installed and functional at $verifyExe. Skipping." 'OK'
                $entry.Method = 'pre-existing'
                $entry.Success = $true
                $Manifest.Packages.Add($entry)
                Save-Manifest
                return
            }
        } else {
            Write-Log "  $($Pkg.Name) already installed at $verifyExe. Skipping." 'OK'
            $entry.Method = 'pre-existing'
            $entry.Success = $true
            $Manifest.Packages.Add($entry)
            Save-Manifest
            return
        }
    }

    if ($verifyCmd -and $Pkg.Name -ne 'nvm-windows') {
        $found = Test-CommandAvailable -Command $verifyCmd -FallbackExes $fallbacks
        if ($found) {
            $ver = try { (& $found --version 2>&1 | Select-Object -First 1) -replace '\s+$','' } catch { 'present' }
            Write-Log "  $($Pkg.Name) already installed ($ver). Skipping." 'OK'
            $entry.Method = 'pre-existing'
            $entry.Success = $true
            $Manifest.Packages.Add($entry)
            Save-Manifest
            return
        }
    }

    if ($Pkg.ContainsKey('VerifyAppx') -and $Pkg.VerifyAppx) {
        $appx = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Pkg.VerifyAppx } |
            Select-Object -First 1

        if ($appx) {
            Write-Log "  $($Pkg.Name) already provisioned ($($appx.Version)). Skipping." 'OK'
            $entry.Method = 'pre-existing'
            $entry.Success = $true
            $Manifest.Packages.Add($entry)
            Save-Manifest
            return
        }
    }

    if ($Pkg.ContainsKey('PreInstall') -and $Pkg.PreInstall) {
        try { & $Pkg.PreInstall } catch { Write-Log "  PreInstall hook error: $_" 'WARN' }
    }

    if ($RunningAsSystem) {
        if (-not $entry.Success -and (Test-Path (Get-BundledPath $Pkg))) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method = 'bundled'
                $entry.Success = $true
            }
        }

        # Only attempt direct download if no bundled file exists; when a bundled
        # file is present Install-ViaDirectDownload would just retry it again.
        if (-not $entry.Success -and -not (Test-Path (Get-BundledPath $Pkg))) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method = 'direct'
                $entry.Success = $true
            }
        }

        if (-not $entry.Success) {
            if (Install-ViaChocolatey $Pkg) {
                $entry.Method = 'choco'
                $entry.Success = $true
            }
        }

        if (-not $entry.Success) {
            if (Install-ViaWinget $Pkg) {
                $entry.Method = 'winget'
                $entry.Success = $true
            }
        }
    } else {
        if (-not $entry.Success) {
            if (Install-ViaWinget $Pkg) {
                $entry.Method = 'winget'
                $entry.Success = $true
            }
        }

        if (-not $entry.Success -and (Test-Path (Get-BundledPath $Pkg))) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method = 'bundled'
                $entry.Success = $true
            }
        }

        # Only attempt direct download if no bundled file exists; when a bundled
        # file is present Install-ViaDirectDownload would just retry it again.
        if (-not $entry.Success -and -not (Test-Path (Get-BundledPath $Pkg))) {
            if (Install-ViaDirectDownload $Pkg) {
                $entry.Method = 'direct'
                $entry.Success = $true
            }
        }

        if (-not $entry.Success) {
            if (Install-ViaChocolatey $Pkg) {
                $entry.Method = 'choco'
                $entry.Success = $true
            }
        }
    }

    if ($entry.Success -and $verifyExe -and -not (Test-Path $verifyExe)) {
        Write-Log "  $($Pkg.Name) reported success but required exe is missing: $verifyExe" 'WARN'
        $entry.Success = $false
    }

    if ($entry.Success -and $Pkg.Name -eq 'nvm-windows') {
        if (-not (Test-NvmRequired)) {
            Write-Log '  nvm install reported success but nvm verification failed.' 'WARN'
            $entry.Success = $false
        }
    }

    if (-not $entry.Success) {
        Add-InstallError "FAILED to install '$($Pkg.Name)' via all available methods."
    }

    $Manifest.Packages.Add($entry)
    Save-Manifest
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
function Install-ClaudeCode {
    Write-Log '=== Claude Code ===' 'INFO'

    if (-not (Install-NodeThroughNvm)) {
        Add-InstallError 'Claude Code was not installed because required nvm/Node setup failed.'
        return
    }

    Update-SessionPath

    $nodeExe = Join-Path $NvmSymlink 'node.exe'
    $npmExe  = Join-Path $NvmSymlink 'npm.cmd'

    if (-not (Test-Path $nodeExe)) {
        Add-InstallError "node.exe missing at required nvm symlink path: $nodeExe"
        return
    }

    if (-not (Test-Path $npmExe)) {
        Add-InstallError "npm.cmd missing at required nvm symlink path: $npmExe"
        return
    }

    if (-not (Test-Path $NpmPrefix)) {
        New-Item -ItemType Directory -Path $NpmPrefix -Force | Out-Null
    }

    Add-MachinePath $NpmPrefix

    $entry = [ordered]@{
        Name      = 'Claude Code'
        Timestamp = (Get-Date -Format 'o')
        Method    = 'npm'
        WingetId  = $null
        ChocoId   = $null
        NpmPkg    = '@anthropic-ai/claude-code'
        Success   = $false
    }

    $wingetStub = 'C:\Program Files\WinGet\Links\claude.exe'
    if (Test-Path $wingetStub) {
        Write-Log '  Removing broken winget Claude stub.' 'DIAG'
        Remove-Item $wingetStub -Force -ErrorAction SilentlyContinue
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Log "  Installing Claude Code via npm attempt $i." 'DIAG'

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $out = & $npmExe install -g '--prefix' $NpmPrefix '@anthropic-ai/claude-code' --loglevel=error 2>&1
        $npmExit = $LASTEXITCODE
        $ErrorActionPreference = $prev

        if ($npmExit -eq 0) {
            Add-MachinePath $NpmPrefix
            Update-SessionPath

            $claudeCmd = Test-CommandAvailable -Command 'claude.cmd' -FallbackExes @(
                'C:\ProgramData\npm\claude.cmd'
            )

            if ($claudeCmd) {
                $ver = try { (& $claudeCmd --version 2>&1 | Select-Object -First 1) -replace '\s+$','' } catch { 'installed' }
                Write-Log "  Claude Code installed: $ver" 'OK'
                $entry.Success = $true
                break
            }

            Write-Log '  npm succeeded but claude.cmd was not found.' 'WARN'
        } else {
            $raw = $out -join "`n"
            Write-Log "  npm failed attempt $i. $raw" 'WARN'
            if ($raw -match '(?i)ECONNRESET|ETIMEDOUT|network') {
                Start-Sleep -Seconds 15
            } else {
                Start-Sleep -Seconds 5
            }
        }
    }

    if (-not $entry.Success) {
        Add-InstallError 'FAILED to install Claude Code.'
    }

    $Manifest.Packages.Add($entry)
    Save-Manifest
}

# ---------------------------------------------------------------------------
# User profile configuration
# ---------------------------------------------------------------------------
function Get-HumanUserProfiles {
    $skip = @(
        'systemprofile',
        'LocalService',
        'NetworkService',
        'defaultuser0',
        'Default',
        'Default User',
        'All Users',
        'Public'
    )

    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin $skip -and
            (Test-Path (Join-Path $_.FullName 'NTUSER.DAT'))
        } |
        Select-Object -ExpandProperty FullName
}

function Configure-ExistingProfiles {
    if (-not (Test-Path $ConfigScript)) {
        Add-InstallWarning 'Configure-UserEnvironment.ps1 not found. Skipping existing profile configuration.'
        return
    }

    $profiles = @(Get-HumanUserProfiles)
    if ($profiles.Count -eq 0) {
        Write-Log 'No existing human user profiles found.' 'DIAG'
        return
    }

    $maxParallel = 3
    $queue = [System.Collections.Queue]::new()
    foreach ($p in $profiles) { $queue.Enqueue($p) }

    $running = [System.Collections.Generic.List[object]]::new()

    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $maxParallel) {
            $prof = [string]$queue.Dequeue()
            $uname = Split-Path $prof -Leaf

            Write-Log "Starting config for: $uname ($prof)" 'INFO'

            $job = Start-Job -ScriptBlock {
                param($script, $profilePath, $setupDir)
                & powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass `
                    -File $script -UserProfile $profilePath -SetupDir $setupDir -SkipVsCodeExtensions 2>&1
            } -ArgumentList $ConfigScript, $prof, $SetupDir

            $running.Add([pscustomobject]@{
                Job = $job
                Name = $uname
                Start = Get-Date
            })
        }

        Start-Sleep -Seconds 2

        foreach ($item in @($running)) {
            if ($item.Job.State -in @('Completed','Failed','Stopped')) {
                try {
                    Receive-Job $item.Job | ForEach-Object {
                        Write-Log "  [$($item.Name)] $_" 'DIAG'
                    }
                } catch {
                    Write-Log "  Failed to collect output for $($item.Name): $_" 'WARN'
                }

                if ($item.Job.State -ne 'Completed') {
                    Add-InstallWarning "User configuration job did not complete cleanly for $($item.Name). State: $($item.Job.State)"
                }

                Remove-Job $item.Job -Force -ErrorAction SilentlyContinue
                [void]$running.Remove($item)
                continue
            }

            if (((Get-Date) - $item.Start).TotalMinutes -gt 15) {
                Write-Log "  Config job timed out for $($item.Name)." 'WARN'
                Stop-Job $item.Job -ErrorAction SilentlyContinue
                try {
                    Receive-Job $item.Job | ForEach-Object {
                        Write-Log "  [$($item.Name)] $_" 'DIAG'
                    }
                } catch { }
                Remove-Job $item.Job -Force -ErrorAction SilentlyContinue
                [void]$running.Remove($item)
                Add-InstallWarning "User configuration timed out for $($item.Name)."
            }
        }
    }
}

function Register-LogonTask {
    Write-Log 'Registering per-user logon configuration task.' 'INFO'

    if (-not (Test-Path $ConfigScript)) {
        Add-InstallWarning 'Configure script missing. Scheduled task not registered.'
        return
    }

    $ps7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $psExe = if (Test-Path $ps7) { $ps7 } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

    $scriptArg = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ConfigScript`" -SetupDir `"$SetupDir`""

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $scriptArg
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited

    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Description 'Configures Master Electronics developer tools for each user on first logon.' `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    Write-Log "Logon task '$TaskName' registered." 'OK'
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
function Invoke-VersionCheck {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Args = @('--version')
    )

    try {
        $job = Start-Job -ScriptBlock {
            param($exe, $args)
            & $exe @args 2>&1 | Select-Object -First 1
        } -ArgumentList $Exe, $Args

        if ($job | Wait-Job -Timeout 8) {
            $out = Receive-Job $job
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            return (($out | Select-Object -First 1) -replace '\s+$','')
        }

        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return 'installed (version check timed out)'
    } catch {
        return 'installed (check error)'
    }
}

function Show-VerificationReport {
    $verifyLog = Join-Path (Split-Path $SetupDir -Parent) 'verify-install.log'
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Update-SessionPath

    $checks = @(
        @{ Label = 'Git';          Cmd = 'git';       Args = @('--version'); Required = $true }
        @{ Label = 'VS Code';      Cmd = 'code';      Args = @('--version'); Required = $true;  FallbackExes = @('C:\Program Files\Microsoft VS Code\Code.exe') }
        @{ Label = 'PowerShell 7'; Cmd = 'pwsh';      Args = @('--version'); Required = $true;  FallbackExes = @('C:\Program Files\PowerShell\7\pwsh.exe') }
        @{ Label = 'nvm';          Cmd = 'nvm';       Args = @('version');   Required = $true;  FallbackExes = @('C:\ProgramData\nvm\nvm.exe') }
        @{ Label = 'Node.js';      Cmd = 'node';      Args = @('--version'); Required = $true;  FallbackExes = @('C:\Program Files\nodejs\node.exe') }
        @{ Label = 'npm';          Cmd = 'npm.cmd';   Args = @('--version'); Required = $true;  FallbackExes = @('C:\Program Files\nodejs\npm.cmd') }
        @{ Label = 'Claude Code';  Cmd = 'claude.cmd';Args = @('--version'); Required = $true;  FallbackExes = @('C:\ProgramData\npm\claude.cmd') }
        @{ Label = 'GitHub CLI';   Cmd = 'gh';        Args = @('--version'); Required = $true }
        @{ Label = 'Docker';       Cmd = 'docker';    Args = @('--version'); Required = $true }
        @{ Label = 'Python';       Cmd = 'python';    Args = @('--version'); Required = $true;  FallbackExes = @('C:\Program Files\Python312\python.exe','C:\Python312\python.exe','C:\ProgramData\chocolatey\bin\python.exe') }
        @{ Label = 'AWS CLI';      Cmd = 'aws';       Args = @('--version'); Required = $false }
        @{ Label = 'Terraform';    Cmd = 'terraform'; Args = @('--version'); Required = $false }
        @{ Label = 'Claude Desktop'; AppxQuery = '*claude*'; Required = $false }
    )

    $lines = @("=== INSTALLATION VERIFICATION  $ts ===")
    $pass = 0
    $missingRequired = 0
    $missingOptional = 0

    Write-Log '' 'INFO'
    Write-Log ('-' * 64) 'INFO'
    Write-Log '  TOOL VERIFICATION' 'INFO'
    Write-Log ('-' * 64) 'INFO'

    foreach ($c in $checks) {
        if ($c.ContainsKey('AppxQuery')) {
            $pkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $c.AppxQuery } |
                Select-Object -First 1

            if ($pkg) {
                $row = "  {0,-17} OK   {1}" -f $c.Label, $pkg.DisplayName
                Write-Log $row 'OK'
                $lines += $row
                $pass++
            } else {
                $row = "  {0,-17} NOT FOUND optional" -f $c.Label
                Write-Log $row 'WARN'
                $lines += $row
                $missingOptional++
            }
            continue
        }

        $fallbacks = if ($c.ContainsKey('FallbackExes')) { $c.FallbackExes } else { @() }
        $exe = Test-CommandAvailable -Command $c.Cmd -FallbackExes $fallbacks

        if ($exe) {
            $ver = Invoke-VersionCheck -Exe $exe -Args $c.Args
            $row = "  {0,-17} OK   {1}" -f $c.Label, $ver
            Write-Log $row 'OK'
            $lines += $row
            $pass++
        } else {
            if ($c.Required) {
                $row = "  {0,-17} NOT FOUND required" -f $c.Label
                Write-Log $row 'FAIL'
                $lines += $row
                $missingRequired++
            } else {
                $row = "  {0,-17} NOT FOUND optional" -f $c.Label
                Write-Log $row 'WARN'
                $lines += $row
                $missingOptional++
            }
        }
    }

    $lines += "  -----------------------------------------------------"
    $lines += "  Pass: $pass   Missing required: $missingRequired   Missing optional: $missingOptional"
    $lines += "=== END ==="
    $lines | Set-Content $verifyLog -Encoding UTF8

    Write-Log ('-' * 64) 'INFO'
    Write-Log "Verification report saved: $verifyLog" 'INFO'

    if ($missingRequired -gt 0) {
        Add-InstallError "Verification failed. Missing required tools: $missingRequired."
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log ('=' * 64) 'INFO'
Write-Log '  Master Electronics - Developer Environment Installer' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log "Role: $Role | MaxRetries: $MaxRetries | RunningAsSystem: $RunningAsSystem" 'INFO'
Write-Log "Log : $LogPath" 'INFO'
Write-Log "Temp: $TempDir" 'INFO'

Set-TlsPolicy
Set-RequiredExecutionPolicy
Update-SessionPath

$localConfig = Join-Path $PSScriptRoot 'Configure-UserEnvironment.ps1'
if (Test-Path $localConfig) {
    Copy-Item $localConfig $ConfigScript -Force
    Write-Log "Configure-UserEnvironment.ps1 copied to $SetupDir" 'OK'
} else {
    Add-InstallWarning 'Configure-UserEnvironment.ps1 not found alongside installer.'
}

$VsCodeExtensions | ConvertTo-Json | Set-Content $ExtListFile -Encoding UTF8

if ($RunningAsSystem) {
    Write-Log 'Running as SYSTEM. Bulk Chocolatey is disabled. Using bundled/direct, Chocolatey, then winget fallback.' 'DIAG'
} else {
    Ensure-Winget | Out-Null
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Repair-WingetSources
    }
}

foreach ($pkg in $Packages) {
    try {
        Install-Package $pkg
    } catch {
        Add-InstallError "Unhandled install error for '$($pkg.Name)': $_"
    }

    Update-SessionPath
}

Install-ClaudeCode
Configure-ExistingProfiles
Register-LogonTask

try {
    Show-VerificationReport
} catch {
    Add-InstallWarning "Verification report error: $_"
}

$Manifest.EndTime = (Get-Date -Format 'o')
Save-Manifest

$failCount = $Manifest.Errors.Count
$warnCount = $Manifest.Warnings.Count

Write-Log '' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log '  INSTALLATION COMPLETE' 'INFO'
Write-Log ('=' * 64) 'INFO'

$elapsed = [datetime]$Manifest.EndTime - [datetime]$Manifest.StartTime
$dur = '{0:D2}m {1:D2}s' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

Write-Log "Duration           : $dur" 'INFO'
Write-Log "Packages attempted : $($Manifest.Packages.Count)" 'INFO'
Write-Log "Warnings           : $warnCount" $(if ($warnCount -gt 0) { 'WARN' } else { 'OK' })
Write-Log "Failures           : $failCount" $(if ($failCount -gt 0) { 'FAIL' } else { 'OK' })

Send-UserNotification -Message 'IT Update: Developer tool installation is complete. Please sign out and back in, or restart your computer, before using Claude Code, PowerShell 7, npm, Docker, or VS Code.' -TimeoutSeconds 120

if ($warnCount -gt 0) {
    Write-Log '' 'INFO'
    Write-Log 'Warnings:' 'WARN'
    foreach ($w in $Manifest.Warnings) {
        Write-Log "  * $w" 'WARN'
    }
}

if ($failCount -gt 0) {
    Write-Log '' 'INFO'
    Write-Log 'Failed items:' 'FAIL'
    foreach ($e in $Manifest.Errors) {
        Write-Log "  * $e" 'FAIL'
    }
    Write-Log "Full log: $LogPath" 'INFO'
    exit 1
}

Write-Log "Full log: $LogPath" 'INFO'
exit 0
