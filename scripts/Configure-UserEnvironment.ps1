<#
.SYNOPSIS
    Configures developer tools for a single Windows user profile.

.DESCRIPTION
    Called in two scenarios:
      1. By Install-DevEnvironment.ps1 (running as SYSTEM) to pre-configure every
         existing user profile on the machine.  In this mode -SkipVsCodeExtensions
         is set because VS Code cannot install extensions without an active user session.
      2. By the scheduled task that fires at each user logon, running as that user.
         In this mode VS Code extensions ARE installed.

    The script is idempotent - it checks before writing so re-runs are safe.

.PARAMETER UserProfile
    Path to the target user profile directory.  Defaults to the current user's profile.

.PARAMETER SetupDir
    The Master Electronics setup directory where vscode-extensions.json is stored.

.PARAMETER SkipVsCodeExtensions
    When present, skip installing VS Code extensions (used when running as SYSTEM).
#>
[CmdletBinding()]
param(
    [string]$UserProfile = $env:USERPROFILE,
    [string]$SetupDir    = 'C:\ProgramData\MasterElectronics\DevSetup',
    [switch]$SkipVsCodeExtensions
)

$ErrorActionPreference = 'Continue'   # Non-fatal - log and keep going
$MarkerFile = Join-Path $UserProfile '.claude\.devsetup-configured'

# -----------------------------------------------------------------------------
# Logging (appends to shared log so IT can read one file)
# Log lives in the PARENT of SetupDir so it survives rollback (rollback deletes
# DevSetup but not the MasterElectronics parent directory).
# -----------------------------------------------------------------------------
$LogParent = Split-Path $SetupDir -Parent   # C:\ProgramData\MasterElectronics
if (-not (Test-Path $LogParent)) { New-Item -ItemType Directory -Path $LogParent -Force | Out-Null }
$LogPath = Join-Path $LogParent 'configure.log'

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $uname = Split-Path $UserProfile -Leaf
    $line  = "[$ts][$Level][$uname] $Msg"
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    $color = switch ($Level) {
        'OK'   { 'Green'  }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red'    }
        'DIAG' { 'Cyan'   }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

# -----------------------------------------------------------------------------
# Determine whether we are running AS the target user or as SYSTEM/admin
# -----------------------------------------------------------------------------
$currentUser   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$targetUser    = Split-Path $UserProfile -Leaf
$runningAsUser = $currentUser -match [regex]::Escape($targetUser)

Write-Log "Configure started. Running as: $currentUser  Target profile: $UserProfile"
Write-Log "Running as target user: $runningAsUser" 'DIAG'

# -----------------------------------------------------------------------------
# Helper - safely create directory
# -----------------------------------------------------------------------------
function Initialize-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 1. Claude Code settings - set preferredShell to Git Bash
# -----------------------------------------------------------------------------
function Set-ClaudeSettings {
    $gitBashExe  = 'C:\Program Files\Git\bin\bash.exe'
    $gitBashExe2 = 'C:\Program Files\Git\usr\bin\bash.exe'
    $bashPath    = if (Test-Path $gitBashExe) { $gitBashExe } `
                   elseif (Test-Path $gitBashExe2) { $gitBashExe2 } `
                   else { $null }

    if (-not $bashPath) {
        Write-Log 'Git Bash not found - skipping Claude settings.' 'WARN'
        return
    }

    $claudeDir      = Join-Path $UserProfile '.claude'
    $settingsPath   = Join-Path $claudeDir 'settings.json'
    Initialize-Dir $claudeDir

    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        } catch {
            $settings = [PSCustomObject]@{}
        }
    } else {
        $settings = [PSCustomObject]@{}
    }

    # Only update if not already set
    if ($settings.PSObject.Properties['preferredShell'] -and
        $settings.preferredShell -eq $bashPath) {
        Write-Log 'Claude preferredShell already configured - skipping.' 'DIAG'
        return
    }

    $settings | Add-Member -Force -NotePropertyName 'preferredShell' -NotePropertyValue $bashPath
    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    Write-Log "Claude settings written: preferredShell = $bashPath" 'OK'
}

# -----------------------------------------------------------------------------
# 2. User PATH - ensure machine-wide tool paths are visible in the user's
#    PATH registry key.  These paths are already in the machine PATH set by
#    the installer, but adding them here ensures visibility even on machines
#    where the machine PATH hasn't propagated to the session yet.
# -----------------------------------------------------------------------------
function Set-UserPath {
    $nvmHome    = [System.Environment]::GetEnvironmentVariable('NVM_HOME',    'Machine')
    $nvmSymlink = [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')

    # Machine-wide paths only - per-user npm prefix removed (npm global is C:\ProgramData\npm)
    $pathsToAdd = @(
        $nvmHome,
        $nvmSymlink,
        'C:\ProgramData\npm'
    ) | Where-Object { $_ -and (Test-Path $_) }

    if (-not $pathsToAdd) {
        Write-Log 'No machine-wide tool paths exist yet - skipping user PATH.' 'DIAG'
        return
    }

    if ($runningAsUser) {
        # We have direct access to HKCU
        $regPath    = 'Registry::HKEY_CURRENT_USER\Environment'
        $pathProp   = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
        $currentVal = if ($pathProp -and $pathProp.PSObject.Properties['Path']) { $pathProp.PSObject.Properties['Path'].Value } else { '' }

        $changed = $false
        foreach ($p in $pathsToAdd) {
            if ($currentVal -notlike "*$p*") {
                $currentVal = ($currentVal.TrimEnd(';') + ";$p").TrimStart(';')
                Write-Log "User PATH: adding $p" 'DIAG'
                $changed = $true
            }
        }
        if ($changed) {
            Set-ItemProperty -Path $regPath -Name Path -Value $currentVal -Type ExpandString
            Write-Log 'User PATH updated.' 'OK'
        } else {
            Write-Log 'User PATH already contains all required entries - skipping.' 'DIAG'
        }
    } else {
        # Running as SYSTEM - try to load the user hive; if NTUSER.DAT is locked
        # (user is currently logged on), fall back to their already-loaded SID hive.
        $hivePath   = Join-Path $UserProfile 'NTUSER.DAT'
        $uname      = Split-Path $UserProfile -Leaf
        $hiveKey    = "HKU\METemp_$uname"
        $hiveLoaded = $false

        if (-not (Test-Path $hivePath)) {
            Write-Log "NTUSER.DAT not found for $uname - skipping user PATH." 'WARN'
            return
        }

        # Resolve registry path: try hive load first, fall back to active SID hive
        $regPath = $null
        & "$env:SystemRoot\System32\reg.exe" load $hiveKey $hivePath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $hiveLoaded = $true
            $regPath    = "Registry::HKEY_USERS\METemp_$uname\Environment"
        } else {
            # NTUSER.DAT is locked - user is currently logged on.
            # Find their already-loaded SID hive under HKU.
            Write-Log "Hive load failed for $uname (user may be logged on) - trying SID hive." 'DIAG'
            try {
                $sid     = (New-Object System.Security.Principal.NTAccount($uname)).Translate(
                               [System.Security.Principal.SecurityIdentifier]).Value
                $sidHive = "Registry::HKEY_USERS\$sid"
                if (Test-Path $sidHive) {
                    $regPath = "$sidHive\Environment"
                    Write-Log "Using active SID hive for $uname ($sid)." 'DIAG'
                }
            } catch {
                Write-Log "Could not resolve SID for ${uname}: $_ - skipping user PATH." 'WARN'
                return
            }
            if (-not $regPath) {
                Write-Log "No loaded hive found for $uname - skipping user PATH." 'WARN'
                return
            }
        }

        try {
            if (-not (Test-Path $regPath)) {
                if ($hiveLoaded) {
                    New-Item -Path $regPath -Force | Out-Null
                } else {
                    # PowerShell's New-Item cannot create keys under active SID hives when
                    # running as SYSTEM - produces "The parameter is incorrect" and escapes
                    # the try-catch.  reg.exe handles active hives correctly.
                    & "$env:SystemRoot\System32\reg.exe" add "HKU\$sid\Environment" /f 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Could not create Environment key for ${uname} - skipping PATH." 'WARN'
                        return
                    }
                }
            }
            $pathProp   = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            $currentVal = if ($pathProp -and $pathProp.PSObject.Properties['Path']) { $pathProp.PSObject.Properties['Path'].Value } else { '' }

            $changed = $false
            foreach ($p in $pathsToAdd) {
                if ($currentVal -notlike "*$p*") {
                    $currentVal = ($currentVal.TrimEnd(';') + ";$p").TrimStart(';')
                    Write-Log "User PATH ($uname): adding $p" 'DIAG'
                    $changed = $true
                }
            }
            if ($changed) {
                Set-ItemProperty -Path $regPath -Name Path -Value $currentVal -Type ExpandString
                Write-Log "User PATH updated for $uname." 'OK'
            } else {
                Write-Log "User PATH already OK for $uname - skipping." 'DIAG'
            }
        } catch {
            Write-Log "Failed to update user PATH for ${uname}: $_" 'WARN'
        } finally {
            if ($hiveLoaded) {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                & "$env:SystemRoot\System32\reg.exe" unload $hiveKey 2>&1 | Out-Null
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 3. Desktop shortcuts for developer tools (VS Code, Git Bash)
# -----------------------------------------------------------------------------
function New-AppShortcuts {
    $wsh     = New-Object -ComObject WScript.Shell
    $desktop = Join-Path $UserProfile 'Desktop'
    Initialize-Dir $desktop

    $apps = @(
        @{
            Name        = 'Visual Studio Code'
            # Machine-wide installer (bundled/direct/choco) always puts VS Code in Program Files.
            # Per-user AppData path uses $UserProfile to avoid LOCALAPPDATA resolving to SYSTEM's profile.
            Targets     = @(
                'C:\Program Files\Microsoft VS Code\Code.exe',
                (Join-Path $UserProfile 'AppData\Local\Programs\Microsoft VS Code\Code.exe')
            )
            Icon        = $null
            Description = 'Visual Studio Code'
        },
        @{
            Name        = 'Git Bash'
            Targets     = @('C:\Program Files\Git\git-bash.exe')
            Icon        = $null
            Description = 'Git Bash'
        }
    )

    foreach ($app in $apps) {
        $target = $app.Targets | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $target) {
            Write-Log "  $($app.Name) not found - skipping desktop shortcut." 'DIAG'
            continue
        }
        $lnkPath   = Join-Path $desktop "$($app.Name).lnk"
        $publicLnk = "C:\Users\Public\Desktop\$($app.Name).lnk"
        if (Test-Path $lnkPath) {
            Write-Log "  $($app.Name) shortcut already exists - skipping." 'DIAG'
            continue
        }
        if (Test-Path $publicLnk) {
            Write-Log "  $($app.Name) shortcut already on Public desktop - skipping per-user copy." 'DIAG'
            continue
        }
        try {
            $lnk                  = $wsh.CreateShortcut($lnkPath)
            $lnk.TargetPath       = $target
            $lnk.WorkingDirectory = Split-Path $target -Parent
            $lnk.Description      = $app.Description
            if ($app.Icon) { $lnk.IconLocation = $app.Icon }
            $lnk.Save()
            Write-Log "  Desktop shortcut created: $($app.Name)" 'OK'
        } catch {
            Write-Log "  Failed to create $($app.Name) shortcut: $_" 'WARN'
        }
    }

    # Claude Desktop - public desktop shortcut (provisioned MSIX, machine-wide).
    # Written to Public desktop so all users see it; skipped if already present.
    $publicClaudeLnk = 'C:\Users\Public\Desktop\Claude.lnk'
    if (-not (Test-Path $publicClaudeLnk)) {
        try {
            $claudePkg = Get-AppxPackage -AllUsers -Name '*Claude*' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
            $claudeExe = if ($claudePkg) { Join-Path $claudePkg.InstallLocation 'Claude.exe' } else { $null }
            if ($claudeExe -and (Test-Path $claudeExe)) {
                $lnk                  = $wsh.CreateShortcut($publicClaudeLnk)
                $lnk.TargetPath       = $claudeExe
                $lnk.WorkingDirectory = $claudePkg.InstallLocation
                $lnk.Description      = 'Claude'
                $lnk.Save()
                Write-Log '  Public desktop shortcut created: Claude' 'OK'
            } else {
                Write-Log '  Claude Desktop AppX package not found - public shortcut skipped.' 'WARN'
            }
        } catch {
            Write-Log "  Failed to create Claude public desktop shortcut: $_" 'WARN'
        }
    } else {
        Write-Log '  Claude public desktop shortcut already exists - skipping.' 'DIAG'
    }
}

# -----------------------------------------------------------------------------
# 4. VS Code extensions
#    When running as SYSTEM (Configure-ExistingProfiles), install directly into
#    each user's VS Code data directory via --user-data-dir so extensions are
#    present on first launch - no logon required.
#    When running as the actual user (logon task), omit --user-data-dir and let
#    VS Code resolve the data directory normally.
# -----------------------------------------------------------------------------
function Install-VsCodeExtensions {
    $codeExe = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeExe) {
        # Try common install paths - machine-wide install goes to Program Files
        $candidates = @(
            'C:\Program Files\Microsoft VS Code\bin\code.cmd',
            (Join-Path $UserProfile 'AppData\Local\Programs\Microsoft VS Code\bin\code.cmd')
        )
        $codePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $codePath) {
            Write-Log 'VS Code not found - skipping extension install.' 'WARN'
            return
        }
        $codeExe = $codePath
    } else {
        $codeExe = $codeExe.Source
    }

    $extListFile = Join-Path $SetupDir 'vscode-extensions.json'
    if (-not (Test-Path $extListFile)) {
        Write-Log 'vscode-extensions.json not found - skipping.' 'WARN'
        return
    }
    $extensions = Get-Content $extListFile | ConvertFrom-Json

    # Build base args: when running as SYSTEM, pin VS Code to the target user's
    # data directory so extensions land in the right place.
    $baseArgs = if ($runningAsUser) {
        @()
    } else {
        $userDataDir  = Join-Path $UserProfile 'AppData\Roaming\Code'
        $extDir       = Join-Path $UserProfile '.vscode\extensions'
        Initialize-Dir $userDataDir
        Initialize-Dir $extDir
        @('--user-data-dir', $userDataDir, '--extensions-dir', $extDir)
    }

    foreach ($ext in $extensions) {
        Write-Log "  Installing VS Code extension: $ext" 'DIAG'
        try {
            $out    = & $codeExe @baseArgs --install-extension $ext --force 2>&1
            $outStr = ($out -join ' ').Trim()
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  Extension OK: $ext" 'OK'
            } else {
                Write-Log "  Extension warning ($ext, exit $LASTEXITCODE): $outStr" 'WARN'
            }
        } catch {
            Write-Log "  Extension install failed ($ext): $_" 'WARN'
        }
    }
}

# -----------------------------------------------------------------------------
# Verification report - quick health check written at end of configure run
# -----------------------------------------------------------------------------
function Show-VerificationReport {
    $verifyLog = Join-Path $LogParent 'verify-configure.log'
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $uname = Split-Path $UserProfile -Leaf

    $lines = @("=== CONFIGURATION VERIFICATION  $ts  [$uname] ===")

    Write-Log '' 'INFO'
    Write-Log ('-' * 64) 'INFO'
    Write-Log '  CONFIGURATION VERIFICATION' 'INFO'
    Write-Log ('-' * 64) 'INFO'

    # Claude settings.json
    $settingsPath = Join-Path $UserProfile '.claude\settings.json'
    if (Test-Path $settingsPath) {
        Write-Log '  Claude settings   OK' 'OK'
        $lines += '  Claude settings   OK'
    } else {
        Write-Log '  Claude settings   NOT FOUND' 'WARN'
        $lines += '  Claude settings   NOT FOUND'
    }

    # Machine PATH contains npm global prefix
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -like '*ProgramData\npm*') {
        Write-Log '  Machine PATH      OK  (C:\ProgramData\npm present)' 'OK'
        $lines += '  Machine PATH      OK  (C:\ProgramData\npm present)'
    } else {
        Write-Log '  Machine PATH      C:\ProgramData\npm missing' 'WARN'
        $lines += '  Machine PATH      C:\ProgramData\npm missing'
    }

    # Desktop shortcuts
    $desktop  = Join-Path $UserProfile 'Desktop'
    $expected = @('Visual Studio Code', 'Git Bash')
    $found    = $expected | Where-Object { Test-Path (Join-Path $desktop "$_.lnk") }
    $row      = "  Shortcuts         {0}/{1}  ({2})" -f $found.Count, $expected.Count, ($found -join ', ')
    $level    = if ($found.Count -gt 0) { 'OK' } else { 'WARN' }
    Write-Log $row $level
    $lines   += $row

    $lines += "=== END ==="
    Write-Log ('-' * 64) 'INFO'

    # Append so multiple user runs accumulate in one file
    Add-Content -Path $verifyLog -Value $lines -Encoding UTF8
    Write-Log "Verification appended to: $verifyLog" 'INFO'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Skip if already fully configured (avoids running on every logon after first-time setup)
if (Test-Path $MarkerFile) {
    Write-Log 'Already configured (marker file present). Run completed.' 'DIAG'
    exit 0
}

if (-not (Test-Path $UserProfile)) {
    Write-Log "User profile path '$UserProfile' does not exist - aborting." 'FAIL'
    exit 1
}

Set-ClaudeSettings
Set-UserPath
New-AppShortcuts
Install-VsCodeExtensions

Show-VerificationReport

# Write marker so the logon task exits immediately on subsequent logins.
# Extensions are now installed during the SYSTEM run (via --user-data-dir), so
# the marker is written regardless of which account ran this script.
Initialize-Dir (Join-Path $UserProfile '.claude')
Set-Content $MarkerFile -Value (Get-Date -Format 'o') -Encoding UTF8
Write-Log 'Configuration complete. Marker file written.' 'OK'

exit 0
