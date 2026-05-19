#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Version-aware patch script for Master Electronics developer environment.

.DESCRIPTION
    For each installed tool, checks the currently installed version against the
    latest version available from the upstream source.  Only tools that are
    out-of-date are updated; already-current tools are skipped entirely.

    Designed to be pulled from GitHub and run by NinjaOne-Patch.ps1 on a
    recurring schedule (weekly / monthly).  Runs as SYSTEM via NinjaOne.

.NOTES
    Logs to: C:\ProgramData\MasterElectronics\patch.log
    Summary: C:\ProgramData\MasterElectronics\patch-summary.log
#>

$ErrorActionPreference = 'Stop'

$Root       = 'C:\ProgramData\MasterElectronics'
$TempDir    = Join-Path $Root 'Patch\Temp'
$LogPath    = Join-Path $Root 'patch.log'
$SummaryPath = Join-Path $Root 'patch-summary.log'
$NvmHome    = 'C:\ProgramData\nvm'
$NvmSymlink = 'C:\Program Files\nodejs'
$NpmPrefix  = 'C:\ProgramData\npm'

foreach ($d in @($TempDir, (Split-Path $LogPath -Parent))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Log([string]$Msg, [string]$Level = 'INFO') {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Msg"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkGray' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

# ── Helpers ───────────────────────────────────────────────────────────────────
function Normalize-Version([string]$v) {
    # Strip leading v, trailing -fallback/-rc so "v3.12.10", "3.12.10-fallback" compare equal.
    ($v -replace '^v', '' -replace '-\w+$', '').Trim()
}

function Compare-Versions([string]$a, [string]$b) {
    # Returns $true if $a and $b represent the same version after normalization.
    (Normalize-Version $a) -eq (Normalize-Version $b)
}

function Invoke-Download([string]$Url, [string]$Dest) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
}

function Invoke-Installer([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 600) {
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -NoNewWindow
    $done = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $done) { try { $proc.Kill() } catch {}; throw "Installer timed out after ${TimeoutSec}s: $FilePath" }
    $proc.WaitForExit()
    $code = $proc.ExitCode
    if ($null -eq $code) { $code = 0 }
    if ($code -notin @(0, 3010, 1641)) { throw "Installer exited $code" }
}

function Get-GitHubLatest([string]$Repo, [string]$AssetPattern, [string]$SkipPattern = '') {
    $ProgressPreference = 'SilentlyContinue'
    if ($SkipPattern) {
        $rels = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=10"
        $rel  = $rels | Where-Object { $_.tag_name -notmatch $SkipPattern -and -not $_.prerelease } | Select-Object -First 1
    } else {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    }
    $tag   = $rel.tag_name
    $asset = $rel.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    [pscustomobject]@{ Version = $tag; Url = $asset.browser_download_url }
}

# ── Tool definitions ──────────────────────────────────────────────────────────
# Each entry: Name, GetInstalled (returns version string or $null), GetLatest (returns version string),
# Update (scriptblock), and optional SkipIf (scriptblock returning $true to skip with a reason string).
$Tools = @(

    @{
        Name         = 'Git for Windows'
        GetInstalled = { try { (& git --version 2>&1) -replace 'git version ','' } catch { $null } }
        GetLatest    = {
            (Get-GitHubLatest 'git-for-windows/git' '-64-bit\.exe$').Version
        }
        Update       = {
            $info = Get-GitHubLatest 'git-for-windows/git' '-64-bit\.exe$'
            $tmp  = Join-Path $TempDir 'git-setup.exe'
            Invoke-Download $info.Url $tmp
            Invoke-Installer $tmp @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'Visual Studio Code'
        GetInstalled = {
            try { (Get-Item 'C:\Program Files\Microsoft VS Code\Code.exe' -ErrorAction Stop).VersionInfo.ProductVersion }
            catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            (Invoke-RestMethod 'https://update.code.visualstudio.com/api/releases/stable')[0]
        }
        Update       = {
            $tmp = Join-Path $TempDir 'vscode-setup.exe'
            Invoke-Download 'https://update.code.visualstudio.com/latest/win32-x64/stable' $tmp
            Invoke-Installer $tmp @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'PowerShell 7'
        GetInstalled = { try { (& pwsh --version 2>&1) -replace 'PowerShell ','' } catch { $null } }
        GetLatest    = { (Get-GitHubLatest 'PowerShell/PowerShell' 'win-x64\.msi$' '-preview|-rc').Version }
        Update       = {
            $info = Get-GitHubLatest 'PowerShell/PowerShell' 'win-x64\.msi$' '-preview|-rc'
            $tmp  = Join-Path $TempDir 'powershell.msi'
            Invoke-Download $info.Url $tmp
            Invoke-Installer 'msiexec.exe' @('/i', $tmp, '/quiet', '/norestart',
                'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1', 'REGISTER_MANIFEST=1', 'USE_MU=1', 'ENABLE_MU=1')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'Python 3.12'
        GetInstalled = {
            try { (& python --version 2>&1) -replace 'Python ','' }
            catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            $rels = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
            ($rels | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } | Select-Object -First 1).tag_name
        }
        Update       = {
            $ProgressPreference = 'SilentlyContinue'
            $rels  = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/releases?per_page=30'
            $rel   = $rels | Where-Object { $_.tag_name -match '^v3\.12\.' -and -not $_.prerelease } | Select-Object -First 1
            $asset = $rel.assets | Where-Object { $_.name -match 'amd64\.exe$' } | Select-Object -First 1
            $url   = if ($asset) { $asset.browser_download_url } else { 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' }
            $tmp   = Join-Path $TempDir 'python-setup.exe'
            Invoke-Download $url $tmp
            Invoke-Installer $tmp @('/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'GitHub CLI'
        GetInstalled = {
            try {
                $v = & gh --version 2>&1 | Select-Object -First 1
                if ($v -match 'gh version (\S+)') { $Matches[1] } else { $null }
            } catch { $null }
        }
        GetLatest    = { (Get-GitHubLatest 'cli/cli' 'windows_amd64\.msi$').Version }
        Update       = {
            $info = Get-GitHubLatest 'cli/cli' 'windows_amd64\.msi$'
            $tmp  = Join-Path $TempDir 'gh-cli.msi'
            Invoke-Download $info.Url $tmp
            Invoke-Installer 'msiexec.exe' @('/i', $tmp, '/quiet', '/norestart')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'AWS CLI v2'
        GetInstalled = {
            try {
                $v = & aws --version 2>&1
                if ($v -match 'aws-cli/(\S+)') { $Matches[1] } else { $null }
            } catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            $rels = Invoke-RestMethod 'https://api.github.com/repos/aws/aws-cli/releases?per_page=10'
            ($rels | Where-Object { $_.tag_name -match '^2\.' -and -not $_.prerelease } | Select-Object -First 1).tag_name
        }
        Update       = {
            $tmp = Join-Path $TempDir 'AWSCLIV2.msi'
            Invoke-Download 'https://awscli.amazonaws.com/AWSCLIV2.msi' $tmp
            Invoke-Installer 'msiexec.exe' @('/i', $tmp, '/quiet', '/norestart')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'Terraform'
        GetInstalled = {
            try {
                $v = & terraform --version 2>&1 | Select-Object -First 1
                ($v -replace 'Terraform v','').Trim()
            } catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            (Invoke-RestMethod 'https://checkpoint-api.hashicorp.com/v1/check/terraform').current_version
        }
        Update       = {
            $ProgressPreference = 'SilentlyContinue'
            $ver = (Invoke-RestMethod 'https://checkpoint-api.hashicorp.com/v1/check/terraform').current_version
            $url = "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip"
            $tmp = Join-Path $TempDir 'terraform.zip'
            Invoke-Download $url $tmp
            $dest = 'C:\Program Files\Terraform'
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Expand-Archive -Path $tmp -DestinationPath $dest -Force
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'Node.js'
        GetInstalled = { try { (& node --version 2>&1).Trim() } catch { $null } }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            ($idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json')
            ($idx | Where-Object { $_.lts -ne $false } | Select-Object -First 1).version
        }
        SkipIf       = {
            if (-not (Test-Path (Join-Path $NvmHome 'nvm.exe'))) {
                'nvm not installed - Node update skipped'
            }
        }
        Update       = {
            $ProgressPreference = 'SilentlyContinue'
            $idx     = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
            $lts     = ($idx | Where-Object { $_.lts -ne $false } | Select-Object -First 1).version
            $nvmExe  = Join-Path $NvmHome 'nvm.exe'
            $env:NVM_HOME    = $NvmHome
            $env:NVM_SYMLINK = $NvmSymlink
            & $nvmExe install $lts 2>&1 | Out-Null
            & $nvmExe use $lts 2>&1 | Out-Null
        }
    }

    @{
        Name         = 'Claude Code'
        GetInstalled = {
            $pkgJson = Join-Path $NpmPrefix 'node_modules\@anthropic-ai\claude-code\package.json'
            try { (Get-Content $pkgJson -Raw | ConvertFrom-Json).version } catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            (Invoke-RestMethod 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest').version
        }
        SkipIf       = {
            $npmCmd = Join-Path $NvmSymlink 'npm.cmd'
            if (-not (Test-Path $npmCmd)) { 'npm not available - Claude Code update skipped' }
        }
        Update       = {
            $npmCmd = Join-Path $NvmSymlink 'npm.cmd'
            $env:npm_config_prefix = $NpmPrefix
            & $npmCmd install -g '@anthropic-ai/claude-code' 2>&1 | Out-Null
        }
    }

    @{
        Name         = 'Claude Desktop'
        GetInstalled = {
            try {
                $pkg = Get-AppxPackage -AllUsers *Claude* -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($pkg) { $pkg.Version } else { $null }
            } catch { $null }
        }
        GetLatest    = { 'always-check' }  # No public version API; always re-provision if installed
        Update       = {
            $tmp = Join-Path $TempDir 'ClaudeDesktop.msix'
            Invoke-Download 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' $tmp
            Add-AppxProvisionedPackage -Online -PackagePath $tmp -SkipLicense -ErrorAction Stop | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        # Claude Desktop has no version API so always update when installed
        AlwaysUpdate = $true
    }

    @{
        Name         = 'Docker Desktop'
        GetInstalled = {
            try {
                $v = & docker --version 2>&1
                if ($v -match 'Docker version (\S+),') { $Matches[1] } else { $null }
            } catch { $null }
        }
        GetLatest    = { 'always-check' }  # Docker has no simple public version API
        SkipIf       = {
            # Skip if Docker engine is actively running - interrupting it risks data loss
            $svc = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                'Docker engine is running - update skipped to avoid interruption'
            }
        }
        Update       = {
            $tmp = Join-Path $TempDir 'DockerDesktopInstaller.exe'
            Invoke-Download 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' $tmp
            Invoke-Installer $tmp @('install', '--quiet', '--accept-license', '--backend=wsl-2') -TimeoutSec 900
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        AlwaysUpdate = $true
    }
)

# ── Main patch loop ───────────────────────────────────────────────────────────
Write-Log ('=' * 60)
Write-Log "Patch-DevEnvironment started on $env:COMPUTERNAME"
Write-Log ('=' * 60)

$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($tool in $Tools) {
    $name = $tool.Name
    Write-Log "--- $name ---"

    # Check optional skip condition first
    if ($tool.ContainsKey('SkipIf') -and $tool.SkipIf) {
        $reason = & $tool.SkipIf
        if ($reason) {
            Write-Log "  $reason" 'SKIP'
            $results.Add([pscustomobject]@{ Name=$name; Status='skipped'; Detail=$reason })
            continue
        }
    }

    # Get installed version
    $installed = try { & $tool.GetInstalled } catch { $null }
    if (-not $installed) {
        Write-Log "  Not installed - skipping." 'SKIP'
        $results.Add([pscustomobject]@{ Name=$name; Status='not installed'; Detail='' })
        continue
    }

    # For always-update tools (no reliable version API), update unconditionally
    if ($tool.ContainsKey('AlwaysUpdate') -and $tool.AlwaysUpdate) {
        Write-Log "  Installed: $installed - updating (no version API, always refresh)." 'INFO'
    } else {
        # Compare installed vs latest
        $latest = $null
        try {
            $latest = & $tool.GetLatest
        } catch {
            Write-Log "  Version check failed: $_ - skipping." 'WARN'
            $results.Add([pscustomobject]@{ Name=$name; Status='check failed'; Detail="$_" })
        }
        if ($null -eq $latest) {
            Write-Log "  Could not determine latest version - skipping." 'WARN'
            $results.Add([pscustomobject]@{ Name=$name; Status='check failed'; Detail='version lookup returned null' })
            continue
        }

        if (Compare-Versions $installed $latest) {
            Write-Log "  Up to date ($installed)." 'OK'
            $results.Add([pscustomobject]@{ Name=$name; Status='up to date'; Detail=$installed })
            continue
        }

        Write-Log "  Update available: $installed -> $latest" 'INFO'
    }

    # Perform update
    try {
        & $tool.Update
        $newVer = try { & $tool.GetInstalled } catch { '?' }
        Write-Log "  Updated successfully. Now at: $newVer" 'OK'
        $results.Add([pscustomobject]@{ Name=$name; Status='updated'; Detail="-> $newVer" })
    } catch {
        Write-Log "  Update failed: $_" 'FAIL'
        $results.Add([pscustomobject]@{ Name=$name; Status='FAILED'; Detail="$_" })
    }
}

# ── Write summary ─────────────────────────────────────────────────────────────
$summaryLines = @(
    "Patch run: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Computer: $env:COMPUTERNAME"
    ''
    ('{0,-22} {1,-14} {2}' -f 'Tool', 'Status', 'Detail')
    ('-' * 70)
)
foreach ($r in $results) {
    $summaryLines += '{0,-22} {1,-14} {2}' -f $r.Name, $r.Status, $r.Detail
}
$summaryLines | Set-Content $SummaryPath -Encoding UTF8

Write-Log ''
Write-Log 'Patch complete. Summary:'
$results | ForEach-Object { Write-Log ('  {0,-22} {1}  {2}' -f $_.Name, $_.Status, $_.Detail) }
Write-Log "Full log: $LogPath"
