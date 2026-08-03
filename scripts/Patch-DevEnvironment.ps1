#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Version-aware patch script for the AIE developer environment.

.DESCRIPTION
    For each installed tool, checks the currently installed version against the
    latest version available from the upstream source.

    Per CAB decision (auto-updating language runtimes/IaC tools was rejected —
    project code can be version-pinned against them, and a silent bump could
    break someone's actual work): only VS Code and Claude Code auto-update when
    out of date. Every other tool (Git, PowerShell 7, Python, GitHub CLI, AWS
    CLI, Terraform, Node.js, Claude Desktop, Docker Desktop) is CHECK-ONLY —
    version drift is checked and reported, but never auto-remediated. Marked via
    the CheckOnly flag on each tool entry.

    Designed to be pulled from GitHub and run by NinjaOne-Patch.ps1 on a
    recurring schedule (weekly / monthly).  Runs as SYSTEM via NinjaOne.

.NOTES
    Logs to: C:\ProgramData\AIE\patch.log
    Summary: C:\ProgramData\AIE\patch-summary.log
#>

$ErrorActionPreference = 'Stop'

$Root       = 'C:\ProgramData\AIE'
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
        CheckOnly    = $true  # CAB: report drift only, no auto-update
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
        CheckOnly    = $true  # CAB: report drift only, no auto-update
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
        CheckOnly    = $true  # CAB: language runtime - code can be version-pinned against it
        GetInstalled = {
            try { (& python --version 2>&1) -replace 'Python ','' }
            catch { $null }
        }
        GetLatest    = {
            # python/cpython publishes ZERO GitHub Releases - /releases always returns
            # an empty array, so this always found $null for "latest" (confirmed
            # 2026-08-01, same bug class as AWS CLI). Also: not every 3.12.x tag has a
            # Windows installer - python.org stops building Windows/macOS binaries once
            # a branch enters security-only maintenance (3.12.11+ are source-only;
            # 3.12.10 is the actual latest with an amd64.exe). Walk down from the
            # highest tag to find the first one with a real installer, so this stays
            # correct without hardcoding a version that will eventually go stale.
            $ProgressPreference = 'SilentlyContinue'
            $tags = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/tags?per_page=100'
            $candidates = $tags | Where-Object { $_.name -match '^v3\.12\.\d+$' } |
                ForEach-Object { [version]($_.name -replace '^v', '') } | Sort-Object -Descending
            $found = $null
            foreach ($candidate in $candidates) {
                $testUrl = "https://www.python.org/ftp/python/$candidate/python-$candidate-amd64.exe"
                try { Invoke-WebRequest -Uri $testUrl -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null; $found = $candidate; break }
                catch { continue }
            }
            "v$found"
        }
        Update       = {
            # Same walk-down logic as GetLatest above - see that comment for why.
            $ProgressPreference = 'SilentlyContinue'
            $tags = Invoke-RestMethod 'https://api.github.com/repos/python/cpython/tags?per_page=100'
            $candidates = $tags | Where-Object { $_.name -match '^v3\.12\.\d+$' } |
                ForEach-Object { [version]($_.name -replace '^v', '') } | Sort-Object -Descending
            $ver = $null
            foreach ($candidate in $candidates) {
                $testUrl = "https://www.python.org/ftp/python/$candidate/python-$candidate-amd64.exe"
                try { Invoke-WebRequest -Uri $testUrl -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null; $ver = $candidate.ToString(); $url = $testUrl; break }
                catch { continue }
            }
            if (-not $ver) { throw "Could not find a Python 3.12.x release with a Windows amd64 installer" }
            $tmp   = Join-Path $TempDir 'python-setup.exe'
            Invoke-Download $url $tmp
            Invoke-Installer $tmp @('/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0')
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    @{
        Name         = 'GitHub CLI'
        CheckOnly    = $true  # CAB: report drift only, no auto-update
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
        CheckOnly    = $true  # CAB: report drift only, no auto-update
        GetInstalled = {
            try {
                $v = & aws --version 2>&1
                if ($v -match 'aws-cli/(\S+)') { $Matches[1] } else { $null }
            } catch { $null }
        }
        GetLatest    = {
            # aws/aws-cli does NOT publish current v2.x versions as GitHub "Releases" -
            # /releases only has a stray 2018 prerelease object, so this always returned
            # $null and every AWS CLI drift check silently no-op'd (confirmed 2026-08-01
            # via the Company Portal updater always showing "update available"). Current
            # versions only exist as plain git tags - use /tags instead.
            $ProgressPreference = 'SilentlyContinue'
            $tags = Invoke-RestMethod 'https://api.github.com/repos/aws/aws-cli/tags?per_page=30'
            ($tags | Where-Object { $_.name -match '^2\.\d+\.\d+$' } |
                ForEach-Object { [version]$_.name } | Sort-Object -Descending | Select-Object -First 1).ToString()
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
        CheckOnly    = $true  # CAB: IaC tool - configs can pin required_version/providers
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
            # Refresh session PATH so the post-update GetInstalled call sees the new exe
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH','User')
        }
    }

    @{
        Name         = 'Node.js'
        CheckOnly    = $true  # CAB: language runtime - code can be version-pinned against it
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
        # Claude Code has been a native binary at C:\ProgramData\Claude\bin\claude.exe
        # since the npm install tier was removed 2026-06-03 (see Install-DevEnvironment.ps1
        # Install-ClaudeCode). This entry previously checked for an npm-installed package,
        # which no longer exists on any current machine — GetInstalled always returned
        # $null, so the main patch loop silently logged "Not installed - skipping" and
        # Claude Code was NEVER actually updated fleet-wide. Fixed to check/update the
        # real native binary, mirroring Install-ClaudeCode's CDN + SHA256 verification
        # exactly. Deliberately does NOT use npm or `claude --update` — the latter creates
        # an orphaned per-user duplicate under C:\Users\<profile>\.local\bin instead of
        # updating the canonical machine-wide binary when run outside a normal interactive
        # user session (confirmed root cause of a July 2026 support incident).
        Name         = 'Claude Code'
        GetInstalled = {
            $claudeExe = 'C:\ProgramData\Claude\bin\claude.exe'
            try {
                $v = & $claudeExe --version 2>&1 | Select-Object -First 1
                if ($v -match '^(\S+)') { $Matches[1] } else { $null }
            } catch { $null }
        }
        GetLatest    = {
            $ProgressPreference = 'SilentlyContinue'
            (Invoke-RestMethod 'https://downloads.claude.ai/claude-code-releases/latest' -UseBasicParsing -ErrorAction Stop).Trim()
        }
        Update       = {
            $ClaudeDir    = 'C:\ProgramData\Claude\bin'
            $ClaudeExe    = Join-Path $ClaudeDir 'claude.exe'
            $DownloadBase = 'https://downloads.claude.ai/claude-code-releases'
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' }

            $version = (Invoke-RestMethod -Uri "$DownloadBase/latest" -UseBasicParsing -ErrorAction Stop).Trim()
            $cdnManifest = Invoke-RestMethod -Uri "$DownloadBase/$version/manifest.json" -UseBasicParsing -ErrorAction Stop
            $expected = $cdnManifest.platforms.$arch.checksum
            if (-not $expected) { throw "Platform $arch not found in Claude Code CDN manifest" }

            $tmpExe = Join-Path $TempDir "claude-$version-$arch.exe"
            Invoke-Download "$DownloadBase/$version/$arch/claude.exe" $tmpExe

            $actual = (Get-FileHash -Path $tmpExe -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
                throw "Checksum mismatch - expected $expected, got $actual"
            }

            # Direct file replacement onto the canonical machine-wide path - not via
            # npm, not via `claude --update`. See comment above for why.
            if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }
            Move-Item $tmpExe $ClaudeExe -Force

            # Move-Item on the same volume (both $TempDir and $ClaudeDir are under C:)
            # is a cheap rename - the file keeps ITS ORIGINAL ACL from $TempDir instead
            # of inheriting $ClaudeDir's permissions. Left unfixed, only the identity
            # that ran this patch script (SYSTEM) could execute the new binary - every
            # other user on the machine would get "Access is denied" (confirmed root
            # cause of a July 2026 support incident). Reset forces it back to inherit
            # from the parent folder, restoring normal execute access for everyone.
            icacls $ClaudeExe /reset | Out-Null
        }
    }

    @{
        # CheckOnly here is largely moot in practice - Claude Desktop already has its
        # own silent background auto-updater (enforced via the enterprise policy set
        # in claude-desktop-intune, autoUpdaterEnforcementHours = 72), so this patch
        # script updating it too would just be redundant. Left check-only per CAB.
        Name         = 'Claude Desktop'
        CheckOnly    = $true
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
        CheckOnly    = $true  # CAB: report drift only, no auto-update
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

    $isCheckOnly  = $tool.ContainsKey('CheckOnly') -and $tool.CheckOnly
    $alwaysUpdate = $tool.ContainsKey('AlwaysUpdate') -and $tool.AlwaysUpdate

    # Tools with no reliable version API (AlwaysUpdate) and CheckOnly can't be
    # compared or safely reported on beyond "here's what's installed" - there's
    # nothing to diff against, and CAB said not to touch it automatically anyway.
    if ($alwaysUpdate -and $isCheckOnly) {
        Write-Log "  Installed: $installed (no public version API - check-only, no action taken)." 'INFO'
        $results.Add([pscustomobject]@{ Name=$name; Status='installed (unknown)'; Detail=$installed })
        continue
    }

    # For always-update tools (no reliable version API), update unconditionally
    if ($alwaysUpdate) {
        Write-Log "  Installed: $installed - updating (no version API, always refresh)." 'INFO'
    } else {
        # Compare installed vs latest
        $latest = $null
        try {
            $latest = & $tool.GetLatest
        } catch {
            Write-Log "  Version check failed: $_ - skipping." 'WARN'
            $results.Add([pscustomobject]@{ Name=$name; Status='check failed'; Detail="$_" })
            continue
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

        # CAB-approved: report drift for this tool, don't remediate it ourselves.
        if ($isCheckOnly) {
            Write-Log "  Update available: $installed -> $latest (check-only - no action taken)" 'WARN'
            $results.Add([pscustomobject]@{ Name=$name; Status='update available'; Detail="$installed -> $latest" })
            continue
        }

        Write-Log "  Update available: $installed -> $latest" 'INFO'
    }

    # Perform update - only reached for tools NOT marked CheckOnly (currently:
    # VS Code and Claude Code, per CAB approval).
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
