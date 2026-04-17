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

    The script is idempotent — it checks before writing so re-runs are safe.

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

$ErrorActionPreference = 'Continue'   # Non-fatal — log and keep going
$MarkerFile = Join-Path $UserProfile '.claude\.devsetup-configured'

# ─────────────────────────────────────────────────────────────────────────────
# Logging (appends to shared log so IT can read one file)
# Log lives in the PARENT of SetupDir so it survives rollback (rollback deletes
# DevSetup but not the MasterElectronics parent directory).
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# Determine whether we are running AS the target user or as SYSTEM/admin
# ─────────────────────────────────────────────────────────────────────────────
$currentUser   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$targetUser    = Split-Path $UserProfile -Leaf
$runningAsUser = $currentUser -match [regex]::Escape($targetUser)

Write-Log "Configure started. Running as: $currentUser  Target profile: $UserProfile"
Write-Log "Running as target user: $runningAsUser" 'DIAG'

# ─────────────────────────────────────────────────────────────────────────────
# Helper — safely create directory
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. npm prefix — write to user's .npmrc
#    nvm-windows sets NVM_HOME/NVM_SYMLINK but per-user npm prefix lives in .npmrc
# ─────────────────────────────────────────────────────────────────────────────
function Set-NpmPrefix {
    $npmRcPath  = Join-Path $UserProfile '.npmrc'
    $npmGlobal  = Join-Path $UserProfile 'AppData\Roaming\npm'

    Ensure-Dir $npmGlobal

    # Only write if prefix line is not already there
    $existing = if (Test-Path $npmRcPath) { Get-Content $npmRcPath -Raw } else { '' }
    if ($existing -notmatch 'prefix\s*=') {
        $prefixLine = "prefix=$($npmGlobal -replace '\\','\\')"
        Add-Content -Path $npmRcPath -Value $prefixLine -Encoding UTF8
        Write-Log "npm prefix set to $npmGlobal in .npmrc" 'OK'
    } else {
        Write-Log 'npm prefix already configured in .npmrc — skipping.' 'DIAG'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. PowerShell profile — add PATH entries for npm global and node
# ─────────────────────────────────────────────────────────────────────────────
function Set-PowerShellProfile {
    # Resolve the CurrentUserAllHosts profile path for the target user.
    # The standard location is Documents\PowerShell\profile.ps1 for PS7
    # and Documents\WindowsPowerShell\profile.ps1 for Windows PowerShell.
    $ps7ProfileDir = Join-Path $UserProfile 'Documents\PowerShell'
    $ps7Profile    = Join-Path $ps7ProfileDir 'profile.ps1'
    $psWinDir      = Join-Path $UserProfile 'Documents\WindowsPowerShell'
    $psWinProfile  = Join-Path $psWinDir 'Microsoft.PowerShell_profile.ps1'

    $npmGlobal = Join-Path $UserProfile 'AppData\Roaming\npm'

    $snippet = @"

# ── Master Electronics DevSetup PATH additions ─────────────────────────────
`$npmGlobalPath = Join-Path `$env:USERPROFILE 'AppData\Roaming\npm'
if ((Test-Path `$npmGlobalPath) -and (`$env:Path -notlike "*`$npmGlobalPath*")) {
    `$env:Path = "`$npmGlobalPath;" + `$env:Path
}
# ──────────────────────────────────────────────────────────────────────────
"@

    foreach ($profilePath in @($ps7Profile, $psWinProfile)) {
        Ensure-Dir (Split-Path $profilePath -Parent)
        $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
        if ($existing -notmatch 'Master Electronics DevSetup PATH') {
            Add-Content -Path $profilePath -Value $snippet -Encoding UTF8
            Write-Log "PowerShell profile updated: $profilePath" 'OK'
        } else {
            Write-Log "Profile already patched: $profilePath — skipping." 'DIAG'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Claude Code settings — set preferredShell to Git Bash
# ─────────────────────────────────────────────────────────────────────────────
function Set-ClaudeSettings {
    $gitBashExe  = 'C:\Program Files\Git\bin\bash.exe'
    $gitBashExe2 = 'C:\Program Files\Git\usr\bin\bash.exe'
    $bashPath    = if (Test-Path $gitBashExe) { $gitBashExe } `
                   elseif (Test-Path $gitBashExe2) { $gitBashExe2 } `
                   else { $null }

    if (-not $bashPath) {
        Write-Log 'Git Bash not found — skipping Claude settings.' 'WARN'
        return
    }

    $claudeDir      = Join-Path $UserProfile '.claude'
    $settingsPath   = Join-Path $claudeDir 'settings.json'
    Ensure-Dir $claudeDir

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
        Write-Log 'Claude preferredShell already configured — skipping.' 'DIAG'
        return
    }

    $settings | Add-Member -Force -NotePropertyName 'preferredShell' -NotePropertyValue $bashPath
    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    Write-Log "Claude settings written: preferredShell = $bashPath" 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. User PATH — ensure npm global, NVM_HOME, and NVM_SYMLINK are in the
#    user-level PATH registry key (complements the PowerShell profile addition
#    for non-PS terminals, and ensures any user gets nvm/node on first logon)
# ─────────────────────────────────────────────────────────────────────────────
function Set-UserPath {
    $npmGlobal  = Join-Path $UserProfile 'AppData\Roaming\npm'
    # Read nvm paths from machine env at call time so any user gets the correct
    # literal paths regardless of when they first logged in (NVM_HOME / NVM_SYMLINK
    # are machine-level env vars set by the nvm installer).
    $nvmHome    = [System.Environment]::GetEnvironmentVariable('NVM_HOME',    'Machine')
    $nvmSymlink = [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')

    # Build the list of paths to ensure are in the user PATH (skip any that don't exist yet)
    $pathsToAdd = @($npmGlobal, $nvmHome, $nvmSymlink) | Where-Object { $_ -and (Test-Path $_) }

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
            Write-Log 'User PATH already contains all required entries — skipping.' 'DIAG'
        }
    } else {
        # Running as SYSTEM — try to load the user hive; if NTUSER.DAT is locked
        # (user is currently logged on), fall back to their already-loaded SID hive.
        $hivePath   = Join-Path $UserProfile 'NTUSER.DAT'
        $uname      = Split-Path $UserProfile -Leaf
        $hiveKey    = "HKU\METemp_$uname"
        $hiveLoaded = $false

        if (-not (Test-Path $hivePath)) {
            Write-Log "NTUSER.DAT not found for $uname — skipping user PATH." 'WARN'
            return
        }

        # Resolve registry path: try hive load first, fall back to active SID hive
        $regPath = $null
        & reg load $hiveKey $hivePath 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $hiveLoaded = $true
            $regPath    = "Registry::HKEY_USERS\METemp_$uname\Environment"
        } else {
            # NTUSER.DAT is locked — user is currently logged on.
            # Find their already-loaded SID hive under HKU.
            Write-Log "Hive load failed for $uname (user may be logged on) — trying SID hive." 'DIAG'
            try {
                $sid     = (New-Object System.Security.Principal.NTAccount($uname)).Translate(
                               [System.Security.Principal.SecurityIdentifier]).Value
                $sidHive = "Registry::HKEY_USERS\$sid"
                if (Test-Path $sidHive) {
                    $regPath = "$sidHive\Environment"
                    Write-Log "Using active SID hive for $uname ($sid)." 'DIAG'
                }
            } catch {
                Write-Log "Could not resolve SID for ${uname}: $_ — skipping user PATH." 'WARN'
                return
            }
            if (-not $regPath) {
                Write-Log "No loaded hive found for $uname — skipping user PATH." 'WARN'
                return
            }
        }

        try {
            if (-not (Test-Path $regPath)) {
                if ($hiveLoaded) {
                    New-Item -Path $regPath -Force | Out-Null
                } else {
                    # PowerShell's New-Item cannot create keys under active SID hives when
                    # running as SYSTEM — produces "The parameter is incorrect" and escapes
                    # the try-catch.  reg.exe handles active hives correctly.
                    & reg add "HKU\$sid\Environment" /f 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Could not create Environment key for ${uname} — skipping PATH." 'WARN'
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
                Write-Log "User PATH already OK for $uname — skipping." 'DIAG'
            }
        } catch {
            Write-Log "Failed to update user PATH for ${uname}: $_" 'WARN'
        } finally {
            if ($hiveLoaded) {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                & reg unload $hiveKey 2>&1 | Out-Null
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Desktop shortcut — "Developer Setup Guide" pointing to the chatbot launcher
# ─────────────────────────────────────────────────────────────────────────────
function New-ChatbotShortcut {
    $launcher  = Join-Path $SetupDir 'chatbot\Start-DevSetupGuide.cmd'
    $shortcut  = Join-Path $UserProfile 'Desktop\Developer Setup Guide.lnk'

    if (-not (Test-Path $launcher)) {
        Write-Log 'Chatbot launcher not found — skipping desktop shortcut.' 'WARN'
        return
    }

    if (Test-Path $shortcut) {
        Write-Log 'Desktop shortcut already exists — skipping.' 'DIAG'
        return
    }

    Ensure-Dir (Split-Path $shortcut -Parent)

    try {
        $wsh    = New-Object -ComObject WScript.Shell
        $lnk    = $wsh.CreateShortcut($shortcut)
        $lnk.TargetPath       = $launcher
        $lnk.WorkingDirectory = Join-Path $SetupDir 'chatbot'
        $lnk.Description      = 'Master Electronics Developer Environment Setup Guide'
        # Use the cmd.exe icon (generic terminal look)
        $lnk.IconLocation     = '%SystemRoot%\system32\cmd.exe,0'
        $lnk.Save()
        Write-Log "Desktop shortcut created: $shortcut" 'OK'
    } catch {
        Write-Log "Failed to create desktop shortcut: $_" 'WARN'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5b. Desktop shortcuts for developer tools (VS Code, Git Bash)
# ─────────────────────────────────────────────────────────────────────────────
function New-AppShortcuts {
    $wsh     = New-Object -ComObject WScript.Shell
    $desktop = Join-Path $UserProfile 'Desktop'
    Ensure-Dir $desktop

    $apps = @(
        @{
            Name        = 'Visual Studio Code'
            # winget installs to per-user AppData on non-SYSTEM runs; machine-wide as fallback
            Targets     = @(
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                'C:\Program Files\Microsoft VS Code\Code.exe'
            )
            Icon        = $null   # use exe's own icon
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
            Write-Log "  $($app.Name) not found — skipping desktop shortcut." 'DIAG'
            continue
        }
        $lnkPath   = Join-Path $desktop "$($app.Name).lnk"
        $publicLnk = "C:\Users\Public\Desktop\$($app.Name).lnk"
        if (Test-Path $lnkPath) {
            Write-Log "  $($app.Name) shortcut already exists — skipping." 'DIAG'
            continue
        }
        if (Test-Path $publicLnk) {
            Write-Log "  $($app.Name) shortcut already on Public desktop — skipping per-user copy." 'DIAG'
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
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. VS Code extensions
#    When running as SYSTEM (Configure-ExistingProfiles), install directly into
#    each user's VS Code data directory via --user-data-dir so extensions are
#    present on first launch — no logon required.
#    When running as the actual user (logon task), omit --user-data-dir and let
#    VS Code resolve the data directory normally.
# ─────────────────────────────────────────────────────────────────────────────
function Install-VsCodeExtensions {
    $codeExe = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeExe) {
        # Try common install paths — machine-wide Choco/direct install goes to Program Files
        $candidates = @(
            'C:\Program Files\Microsoft VS Code\bin\code.cmd',
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
        )
        $codePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $codePath) {
            Write-Log 'VS Code not found — skipping extension install.' 'WARN'
            return
        }
        $codeExe = $codePath
    } else {
        $codeExe = $codeExe.Source
    }

    $extListFile = Join-Path $SetupDir 'vscode-extensions.json'
    if (-not (Test-Path $extListFile)) {
        Write-Log 'vscode-extensions.json not found — skipping.' 'WARN'
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
        Ensure-Dir $userDataDir
        Ensure-Dir $extDir
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

# ─────────────────────────────────────────────────────────────────────────────
# Verification report — quick health check written at end of configure run
# ─────────────────────────────────────────────────────────────────────────────
function Show-VerificationReport {
    $verifyLog = Join-Path $LogParent 'verify-configure.log'
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $uname = Split-Path $UserProfile -Leaf

    $lines = @("=== CONFIGURATION VERIFICATION  $ts  [$uname] ===")

    Write-Log '' 'INFO'
    Write-Log ('─' * 64) 'INFO'
    Write-Log '  CONFIGURATION VERIFICATION' 'INFO'
    Write-Log ('─' * 64) 'INFO'

    # npm prefix in .npmrc
    $npmRcPath = Join-Path $UserProfile '.npmrc'
    if ((Test-Path $npmRcPath) -and ((Get-Content $npmRcPath -Raw -ErrorAction SilentlyContinue) -match 'prefix\s*=')) {
        Write-Log '  npm prefix        OK' 'OK'
        $lines += '  npm prefix        OK'
    } else {
        Write-Log '  npm prefix        NOT SET' 'WARN'
        $lines += '  npm prefix        NOT SET'
    }

    # PS7 profile patched
    $ps7Profile = Join-Path $UserProfile 'Documents\PowerShell\profile.ps1'
    if ((Test-Path $ps7Profile) -and ((Get-Content $ps7Profile -Raw -ErrorAction SilentlyContinue) -match 'Master Electronics DevSetup')) {
        Write-Log '  PS7 profile       OK' 'OK'
        $lines += '  PS7 profile       OK'
    } else {
        Write-Log '  PS7 profile       NOT PATCHED' 'WARN'
        $lines += '  PS7 profile       NOT PATCHED'
    }

    # PS5 profile patched
    $ps5Profile = Join-Path $UserProfile 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    if ((Test-Path $ps5Profile) -and ((Get-Content $ps5Profile -Raw -ErrorAction SilentlyContinue) -match 'Master Electronics DevSetup')) {
        Write-Log '  PS5 profile       OK' 'OK'
        $lines += '  PS5 profile       OK'
    } else {
        Write-Log '  PS5 profile       NOT PATCHED' 'WARN'
        $lines += '  PS5 profile       NOT PATCHED'
    }

    # Claude settings.json
    $settingsPath = Join-Path $UserProfile '.claude\settings.json'
    if (Test-Path $settingsPath) {
        Write-Log '  Claude settings   OK' 'OK'
        $lines += '  Claude settings   OK'
    } else {
        Write-Log '  Claude settings   NOT FOUND' 'WARN'
        $lines += '  Claude settings   NOT FOUND'
    }

    # User PATH registry entry
    $regPath  = 'Registry::HKEY_CURRENT_USER\Environment'
    $userPath = (Get-ItemProperty $regPath -Name Path -ErrorAction SilentlyContinue).Path
    $npmGlobal = Join-Path $UserProfile 'AppData\Roaming\npm'
    if ($userPath -and $userPath -like "*npm*") {
        Write-Log "  User PATH         OK  ($npmGlobal)" 'OK'
        $lines += "  User PATH         OK  ($npmGlobal)"
    } else {
        Write-Log '  User PATH         npm global missing' 'WARN'
        $lines += '  User PATH         npm global missing'
    }

    # Desktop shortcuts — use the target user's profile path, not the running user's
    # GetFolderPath('Desktop') returns the *current* user's desktop, which is wrong
    # when this script is invoked by SYSTEM or another admin for a different profile.
    $desktop  = Join-Path $UserProfile 'Desktop'
    $expected = @('Developer Setup Guide', 'Visual Studio Code', 'Git Bash')
    $found    = $expected | Where-Object { Test-Path (Join-Path $desktop "$_.lnk") }
    $row      = "  Shortcuts         {0}/{1}  ({2})" -f $found.Count, $expected.Count, ($found -join ', ')
    $level    = if ($found.Count -gt 0) { 'OK' } else { 'WARN' }
    Write-Log $row $level
    $lines   += $row

    $lines += "=== END ==="
    Write-Log ('─' * 64) 'INFO'

    # Append so multiple user runs accumulate in one file
    Add-Content -Path $verifyLog -Value $lines -Encoding UTF8
    Write-Log "Verification appended to: $verifyLog" 'INFO'
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

# Skip if already fully configured (avoids running on every logon after first-time setup)
if (Test-Path $MarkerFile) {
    Write-Log 'Already configured (marker file present). Run completed.' 'DIAG'
    exit 0
}

if (-not (Test-Path $UserProfile)) {
    Write-Log "User profile path '$UserProfile' does not exist — aborting." 'FAIL'
    exit 1
}

Set-NpmPrefix
Set-PowerShellProfile
Set-ClaudeSettings
Set-UserPath
New-ChatbotShortcut
New-AppShortcuts
Install-VsCodeExtensions

Show-VerificationReport

# Write marker so the logon task exits immediately on subsequent logins.
# Extensions are now installed during the SYSTEM run (via --user-data-dir), so
# the marker is written regardless of which account ran this script.
Ensure-Dir (Join-Path $UserProfile '.claude')
Set-Content $MarkerFile -Value (Get-Date -Format 'o') -Encoding UTF8
Write-Log 'Configuration complete. Marker file written.' 'OK'

exit 0



















