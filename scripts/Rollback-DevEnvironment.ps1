#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reverses everything Install-DevEnvironment.ps1 did, using the manifest it wrote.

.DESCRIPTION
    Reads C:\ProgramData\MasterElectronics\DevSetup\manifest.json, uninstalls every
    package in reverse order using the method that originally installed it (winget,
    Chocolatey, npm, or a direct uninstaller), removes per-user configuration changes
    from all human user profiles, unregisters the logon scheduled task, and finally
    removes the setup directory itself.

.PARAMETER ManifestPath
    Path to the manifest JSON written by Install-DevEnvironment.ps1.

.PARAMETER LogPath
    Path for the rollback log file.

.PARAMETER Force
    Skip the confirmation prompt and proceed immediately.

.EXAMPLE
    # Interactive rollback (prompts for confirmation):
    powershell.exe -ExecutionPolicy Bypass -File Rollback-DevEnvironment.ps1

    # Non-interactive (e.g. from NinjaOne):
    powershell.exe -ExecutionPolicy Bypass -File Rollback-DevEnvironment.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath = 'C:\ProgramData\MasterElectronics\DevSetup\manifest.json',
    [string]$LogPath      = 'C:\ProgramData\MasterElectronics\rollback.log',
    [switch]$Force,

    # Skip manifest-based uninstalls and run only the force-cleanup section.
    # Use this when the manifest is gone (e.g. a prior rollback already deleted it)
    # but tool remnants or user profile changes are still present.
    [switch]$ForceCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$SetupDir = Split-Path $ManifestPath -Parent
$TaskName = 'MasterElectronics-ConfigureUserEnvironment'

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Msg"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
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
# Registry-based uninstall — reads HKLM uninstall entries and invokes the
# uninstaller directly.  Works as SYSTEM without WinRT/COM dependencies,
# which winget requires and lacks in a headless SYSTEM session.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-RegistryUninstall {
    param([string]$DisplayNamePattern)

    $searchPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = $null
    foreach ($p in $searchPaths) {
        $found = Get-ItemProperty $p -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayNamePattern } |
                 Select-Object -First 1
        if ($found) { $entry = $found; break }
    }

    if (-not $entry) {
        Write-Log "  No registry uninstall entry found for '$DisplayNamePattern'." 'DIAG'
        return $false
    }

    # Prefer QuietUninstallString; fall back to UninstallString
    $rawStr = if ($entry.PSObject.Properties['QuietUninstallString'] -and $entry.QuietUninstallString) { $entry.QuietUninstallString }
              elseif ($entry.PSObject.Properties['UninstallString'])                                   { $entry.UninstallString }
              else                                                                                      { $null }

    if (-not $rawStr) {
        Write-Log "  Registry entry for '$DisplayNamePattern' has no uninstall string." 'DIAG'
        return $false
    }

    Write-Log "  Invoking registry uninstaller for '$DisplayNamePattern'…" 'DIAG'

    try {
        if ($rawStr -match 'msiexec') {
            $code = [regex]::Match($rawStr, '\{[^}]+\}').Value
            if (-not $code) {
                Write-Log "  Could not parse MSI product code from uninstall string." 'DIAG'
                return $false
            }
            $proc = Start-Process 'msiexec.exe' `
                        -ArgumentList "/X $code /quiet /norestart" `
                        -Wait -PassThru -NoNewWindow
            # 0 = success; 1605 = product not registered (already removed)
            return ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1605)
        } else {
            # INNO Setup, NSIS, Squirrel, etc. — parse quoted or unquoted exe path
            if ($rawStr -match '^"([^"]+)"(.*)$') {
                $exePath = $Matches[1]; $exeArgs = $Matches[2].Trim()
            } else {
                $parts   = $rawStr -split ' ', 2
                $exePath = $parts[0]
                $exeArgs = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            }

            if (-not (Test-Path $exePath)) {
                Write-Log "  Uninstall exe not found at: $exePath" 'DIAG'
                return $false
            }

            $silentArgs = '/SILENT /NORESTART /SUPPRESSMSGBOXES /SP-'
            $allArgs    = if ($exeArgs) { "$exeArgs $silentArgs" } else { $silentArgs }
            $proc = Start-Process $exePath -ArgumentList $allArgs -Wait -PassThru -NoNewWindow
            # INNO returns 0 (clean) or 1 (partial — acceptable); treat both as success
            return ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 1)
        }
    } catch {
        Write-Log "  Registry uninstall threw: $_" 'WARN'
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Load manifest
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $ManifestPath)) {
    if ($ForceCleanup) {
        Write-Log "Manifest not found — running force-cleanup only (no manifest-based uninstalls)." 'WARN'
        # Create a dummy manifest so the rest of the script can reference $manifest safely
        $manifest = [PSCustomObject]@{ Packages = @(); ChocolateyInstalled = $false; StartTime = ''; Role = '' }
        $packages = @()
    } elseif (-not $Force) {
        # Interactive session — offer to switch to ForceCleanup rather than just erroring out.
        Write-Host ''
        Write-Host "WARNING: Manifest not found at '$ManifestPath'." -ForegroundColor Yellow
        Write-Host 'No install record exists, so package uninstalls cannot be driven by the manifest.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'ForceCleanup mode will skip manifest-based uninstalls and instead:' -ForegroundColor Cyan
        Write-Host '  - Remove known tool directories and environment variables directly' -ForegroundColor Cyan
        Write-Host '  - Clean user profile PATH entries and Claude settings for all profiles' -ForegroundColor Cyan
        Write-Host '  - Retry winget uninstall for any tools still found on PATH' -ForegroundColor Cyan
        Write-Host ''
        $answer = Read-Host 'Run in ForceCleanup mode? Type YES to continue'
        if ($answer -eq 'YES') {
            $ForceCleanup = $true
            Write-Log "Manifest not found — running force-cleanup only (no manifest-based uninstalls)." 'WARN'
            $manifest = [PSCustomObject]@{ Packages = @(); ChocolateyInstalled = $false; StartTime = ''; Role = '' }
            $packages = @()
        } else {
            Write-Host 'Rollback cancelled.' -ForegroundColor Cyan
            exit 0
        }
    } else {
        # -Force (non-interactive) with no manifest and no -ForceCleanup — require explicit flag.
        Write-Host "ERROR: Manifest not found at '$ManifestPath'. Pass -ForceCleanup to remove remnants without a manifest." -ForegroundColor Red
        exit 1
    }
} else {
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $packages = @($manifest.Packages)
}

Write-Log ('=' * 64) 'INFO'
Write-Log '  Master Electronics — Developer Environment ROLLBACK' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log "Manifest: $ManifestPath" 'INFO'
Write-Log "Installed: $($manifest.StartTime)  Role: $($manifest.Role)" 'INFO'
Write-Log "Packages to remove: $($packages.Count)" 'INFO'

# ─────────────────────────────────────────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────────────────────────────────────────
if (-not $Force -and -not $ForceCleanup) {
    Write-Host ''
    Write-Host 'This will UNINSTALL all packages installed by Install-DevEnvironment.ps1' -ForegroundColor Yellow
    Write-Host 'and remove developer configuration from all user profiles.' -ForegroundColor Yellow
    Write-Host ''
    $answer = Read-Host 'Type YES to continue'
    if ($answer -ne 'YES') {
        Write-Host 'Rollback cancelled.' -ForegroundColor Cyan
        exit 0
    }
}

$errors = [System.Collections.Generic.List[string]]::new()

if ($ForceCleanup) {
    Write-Log 'ForceCleanup mode — skipping manifest-based package uninstalls.' 'WARN'
} else {

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall packages in REVERSE order
# ─────────────────────────────────────────────────────────────────────────────
[array]::Reverse($packages)

foreach ($pkg in $packages) {
    if (-not $pkg.Success) {
        Write-Log "Skipping '$($pkg.Name)' — was not successfully installed." 'DIAG'
        continue
    }

    Write-Log "=== Uninstalling $($pkg.Name) (method: $($pkg.Method)) ===" 'INFO'

    $removed = $false

    switch ($pkg.Method) {
        'winget' {
            if ($pkg.WingetId) {
                # NVM for Windows uses an Inno Setup uninstaller that supports /VERYSILENT.
                # Calling it directly avoids the confirmation dialog winget triggers.
                if ($pkg.WingetId -eq 'CoreyButler.NVMforWindows') {
                    $nvmHome = [System.Environment]::GetEnvironmentVariable('NVM_HOME', 'Machine')
                    if (-not $nvmHome) { $nvmHome = 'C:\ProgramData\nvm' }
                    $nvmUninstaller = Join-Path $nvmHome 'unins000.exe'
                    if (Test-Path $nvmUninstaller) {
                        Write-Log '  Running NVM for Windows silent uninstaller directly…' 'DIAG'
                        $proc = Start-Process $nvmUninstaller -ArgumentList '/VERYSILENT /NORESTART' -PassThru -NoNewWindow
                        $finished = $proc.WaitForExit(120000)
                        if (-not $finished) { $proc.Kill(); Write-Log '  NVM uninstaller timed out — killed.' 'WARN' }
                        elseif ($proc.ExitCode -eq 0) { Write-Log '  NVM for Windows uninstalled silently.' 'OK'; $removed = $true }
                        else { Write-Log "  NVM uninstaller exit $($proc.ExitCode) — falling back to winget." 'WARN' }
                    }
                }

                if (-not $removed) {
                    Write-Log "  Running winget uninstall (up to 3 min)…" 'DIAG'
                    $wingetId = $pkg.WingetId
                    # Use Start-Job so & winget runs in a real console context (Start-Process
                    # -NoNewWindow gives winget a null exit code on MSIX-packaged builds).
                    $job = Start-Job -ScriptBlock {
                        $out = & winget uninstall --id $args[0] --silent --accept-source-agreements 2>&1
                        [PSCustomObject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
                    } -ArgumentList $wingetId
                    $completed = Wait-Job $job -Timeout 180
                    if (-not $completed) {
                        Stop-Job $job; Remove-Job $job -Force
                        Write-Log "  winget uninstall timed out for $($pkg.WingetId) — killed." 'WARN'
                    } else {
                        $result = Receive-Job $job; Remove-Job $job -Force
                        if ($result.ExitCode -eq 0 -or $result.Output -match '(?i)not found|not installed|no installed') {
                            Write-Log "  winget uninstall OK: $($pkg.WingetId)" 'OK'
                            $removed = $true
                        } else {
                            Write-Log "  winget uninstall warning (exit $($result.ExitCode))" 'WARN'
                        }
                    }
                    # Docker Desktop spawns a post-uninstall UI dialog even with --silent.
                    # Kill it so it cannot block execution in a headless/SYSTEM context.
                    if ($pkg.WingetId -eq 'Docker.DockerDesktop') {
                        Get-Process -Name 'Docker Desktop Installer' -ErrorAction SilentlyContinue |
                            Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-Log '  Killed Docker Desktop Installer UI (post-uninstall dialog).' 'DIAG'
                        # winget removes the daemon but leaves CLI binaries in C:\Program Files\Docker.
                        # Remove the remaining directory so 'docker' is fully gone.
                        $dockerDir = 'C:\Program Files\Docker'
                        if (Test-Path $dockerDir) {
                            try {
                                Remove-Item $dockerDir -Recurse -Force -ErrorAction Stop
                                Write-Log '  Removed leftover Docker CLI directory.' 'OK'
                            } catch {
                                Write-Log "  Could not remove Docker directory: $_" 'WARN'
                            }
                        }
                    }
                } # end if (-not $removed)
            }
        }
        'choco' {
            if ($pkg.ChocoId -and (Get-Command choco -ErrorAction SilentlyContinue)) {
                $chocoId  = $pkg.ChocoId
                $maxTries = 3
                for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
                    Write-Log "  Running choco uninstall (up to 2 min)…" 'DIAG'
                    $job = Start-Job -ScriptBlock {
                        $out = & choco uninstall $args[0] --yes --no-progress 2>&1
                        [PSCustomObject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
                    } -ArgumentList $chocoId
                    $completed = Wait-Job $job -Timeout 120
                    if (-not $completed) {
                        Stop-Job $job; Remove-Job $job -Force
                        Write-Log "  choco uninstall timed out for $($pkg.ChocoId) — killed." 'WARN'
                        break
                    }
                    $result = Receive-Job $job; Remove-Job $job -Force
                    if ($result.ExitCode -eq 0) {
                        Write-Log "  choco uninstall OK: $($pkg.ChocoId)" 'OK'
                        $removed = $true
                        break
                    } elseif ($result.ExitCode -eq 1618) {
                        Write-Log "  choco uninstall exit 1618 (MSI lock) — waiting 20s before retry ($attempt/$maxTries)…" 'WARN'
                        if ($attempt -lt $maxTries) { Start-Sleep -Seconds 20 }
                    } else {
                        Write-Log "  choco uninstall exit $($result.ExitCode)" 'WARN'
                        break
                    }
                }
                # choco uninstall failed — fall back to registry uninstaller so the MSI
                # entry is removed even when choco can't drive the uninstall (e.g. Python
                # exit 1603 due to registry/file state mismatch from a prior partial install).
                if (-not $removed) {
                    $pattern = "*$($pkg.Name)*"
                    Write-Log "  choco uninstall failed — trying registry uninstaller for '$pattern'…" 'DIAG'
                    $removed = Invoke-RegistryUninstall -DisplayNamePattern $pattern
                    if ($removed) { Write-Log "  Registry uninstall OK: $($pkg.Name)" 'OK' }
                }
            }
        }
        'npm' {
            # Claude Code specifically
            if (Get-Command npm -ErrorAction SilentlyContinue) {
                $out = & npm uninstall -g '--prefix' 'C:\ProgramData\npm' '@anthropic-ai/claude-code' 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log '  npm uninstall OK: @anthropic-ai/claude-code' 'OK'
                    $removed = $true
                } else {
                    Write-Log "  npm uninstall exit $LASTEXITCODE" 'WARN'
                }
            }
        }
        'direct' {
            # nvm-noinstall.zip has no uninstaller — remove the directory and registry entries directly.
            if ($pkg.Name -eq 'nvm-windows') {
                $nvmHome    = [System.Environment]::GetEnvironmentVariable('NVM_HOME',    'Machine')
                $nvmSymlink = [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')
                if (-not $nvmHome)    { $nvmHome    = 'C:\ProgramData\nvm'      }
                if (-not $nvmSymlink) { $nvmSymlink = 'C:\Program Files\nodejs' }

                if (Test-Path $nvmHome) {
                    try {
                        Remove-Item $nvmHome -Recurse -Force -ErrorAction Stop
                        Write-Log "  Removed nvm directory: $nvmHome" 'OK'
                        $removed = $true
                    } catch {
                        Write-Log "  Could not remove nvm directory: $_" 'WARN'
                    }
                } else {
                    Write-Log "  nvm directory not found ($nvmHome) — already removed." 'DIAG'
                    $removed = $true
                }

                if (Test-Path $nvmSymlink) {
                    Remove-Item $nvmSymlink -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "  Removed nodejs directory: $nvmSymlink" 'OK'
                }

                # Clean up machine-level env vars
                [System.Environment]::SetEnvironmentVariable('NVM_HOME',    $null, 'Machine')
                [System.Environment]::SetEnvironmentVariable('NVM_SYMLINK', $null, 'Machine')

                # Remove nvm/nodejs entries from machine PATH
                $mp    = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
                $newMp = ($mp -split ';' | Where-Object { $_ -and $_ -ne $nvmHome -and $_ -ne $nvmSymlink }) -join ';'
                if ($newMp -ne $mp) {
                    [System.Environment]::SetEnvironmentVariable('Path', $newMp, 'Machine')
                    Write-Log '  Removed nvm/nodejs entries from machine PATH.' 'OK'
                }
            }

            # For all other direct installs (and nvm if directory removal failed),
            # attempt winget uninstall by display name as best effort.
            if (-not $removed -and $pkg.WingetId) {
                Write-Log "  Attempting winget uninstall for direct-installed '$($pkg.Name)'…" 'DIAG'
                $proc = Start-Process -FilePath 'winget' `
                    -ArgumentList "uninstall --id $($pkg.WingetId) --silent" `
                    -PassThru -NoNewWindow
                $finished = $proc.WaitForExit(120000)
                if (-not $finished) {
                    $proc.Kill()
                    Write-Log "  winget uninstall timed out — killed." 'WARN'
                } elseif ($proc.ExitCode -eq 0) {
                    Write-Log "  winget uninstall OK" 'OK'
                    $removed = $true
                }
            }
            if (-not $removed) {
                # Fall back to Programs & Features search by display name
                $uninstallKey = @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                )
                $entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -like "*$($pkg.Name)*" } |
                         Select-Object -First 1
                if ($entry -and $entry.UninstallString) {
                    Write-Log "  Running uninstall string: $($entry.UninstallString)" 'DIAG'
                    try {
                        $us = $entry.UninstallString
                        # Inject silent flags if possible
                        if ($us -match '(?i)msiexec') {
                            $p = Start-Process msiexec.exe -ArgumentList "/x `"$($entry.PSChildName)`" /quiet /norestart" -Wait -PassThru -NoNewWindow
                        } else {
                            $p = Start-Process cmd.exe -ArgumentList "/c `"$us`" /S /silent /quiet" -Wait -PassThru -NoNewWindow
                        }
                        Write-Log "  Uninstaller exit: $($p.ExitCode)" $(if ($p.ExitCode -eq 0) { 'OK' } else { 'WARN' })
                        $removed = ($p.ExitCode -eq 0)
                    } catch {
                        Write-Log "  Uninstaller error: $_" 'WARN'
                    }
                } else {
                    Write-Log "  No uninstall entry found for '$($pkg.Name)' — manual removal may be needed." 'WARN'
                }
            }
        }
        default {
            Write-Log "  Unknown install method '$($pkg.Method)' for '$($pkg.Name)'." 'WARN'
        }
    }

    if (-not $removed) {
        $errors.Add("Could not remove '$($pkg.Name)' automatically.")
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Claude Code — remove unconditionally, outside the manifest success gate.
# The install step records Success=false when npm was unavailable (e.g. Node
# failed to install via nvm), even when claude was already present on the
# machine from a prior install.  Always attempt removal if the binary exists.
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Claude Code cleanup ===' 'INFO'

# Refresh PATH so changes from the package uninstalls above are reflected
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

if (Get-Command claude -ErrorAction SilentlyContinue) {
    $claudePath = (Get-Command claude).Source
    Write-Log "  claude found at: $claudePath" 'DIAG'
    $ccRemoved = $false

    # Prefer npm uninstall when npm is available
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $out = & npm uninstall -g '--prefix' 'C:\ProgramData\npm' '@anthropic-ai/claude-code' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log '  npm uninstall OK: @anthropic-ai/claude-code' 'OK'
            $ccRemoved = $true
        } else {
            Write-Log "  npm uninstall exit $LASTEXITCODE — falling back to direct removal." 'WARN'
        }
    }

    # npm not available or failed: remove wrapper scripts and package directory directly
    if (-not $ccRemoved) {
        try {
            $binDir = Split-Path $claudePath -Parent
            Get-ChildItem $binDir -Filter 'claude*' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed claude wrapper scripts from $binDir" 'OK'

            $pkgDir = Join-Path (Split-Path $binDir -Parent) 'node_modules\@anthropic-ai\claude-code'
            if (Test-Path $pkgDir) {
                Remove-Item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log '  Removed @anthropic-ai/claude-code from node_modules' 'OK'
            }
            $ccRemoved = $true
        } catch {
            Write-Log "  Direct removal error: $_" 'WARN'
            $errors.Add("Could not remove Claude Code automatically.")
        }
    }
} else {
    Write-Log '  claude not found — nothing to remove.' 'DIAG'
}

# Registry pass — catches Claude Code registered as a Windows app (e.g. standalone installer)
Invoke-RegistryUninstall -DisplayNamePattern '*Claude Code*' | Out-Null

} # end if (-not $ForceCleanup)

# ─────────────────────────────────────────────────────────────────────────────
# Remove per-user configuration from all profiles
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Cleaning up user profile configurations ===' 'INFO'

$skip = @('systemprofile','LocalService','NetworkService','defaultuser0','Default','All Users','Public')
$userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skip -and (Test-Path (Join-Path $_.FullName 'NTUSER.DAT')) }

foreach ($profDir in $userProfiles) {
    $prof  = $profDir.FullName
    $uname = $profDir.Name
    Write-Log "Cleaning profile: $uname" 'DIAG'

    # Remove entire .claude directory (settings, auth token, marker — everything we created)
    $claudeDir = Join-Path $prof '.claude'
    if (Test-Path $claudeDir) {
        try {
            Remove-Item $claudeDir -Recurse -Force -ErrorAction Stop
            Write-Log "  Removed .claude dir for $uname" 'OK'
        } catch {
            Write-Log "  Could not remove .claude dir for ${uname}: $_" 'WARN'
        }
    }

    # Remove .vscode directory (VS Code user settings and extensions)
    $vscodeDir = Join-Path $prof '.vscode'
    if (Test-Path $vscodeDir) {
        try {
            Remove-Item $vscodeDir -Recurse -Force -ErrorAction Stop
            Write-Log "  Removed .vscode dir for $uname" 'OK'
        } catch {
            Write-Log "  Could not remove .vscode dir for ${uname}: $_" 'WARN'
        }
    }

    # Remove .npmrc — strip our prefix line; delete file if nothing else remains
    $npmRc = Join-Path $prof '.npmrc'
    if (Test-Path $npmRc) {
        $content = Get-Content $npmRc -Raw
        $cleaned = ($content -split "`n" | Where-Object { $_ -notmatch '^prefix\s*=' }) -join "`n"
        if ($cleaned.Trim() -eq '') {
            Remove-Item $npmRc -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed .npmrc for $uname" 'OK'
        } elseif ($cleaned -ne $content) {
            Set-Content $npmRc -Value $cleaned.TrimEnd() -Encoding UTF8
            Write-Log "  Removed npm prefix from .npmrc for $uname" 'OK'
        }
    }

    # Remove per-user Docker AppData directories
    foreach ($dockerRel in @('AppData\Roaming\Docker', 'AppData\Local\Docker')) {
        $dockerDir = Join-Path $prof $dockerRel
        if (Test-Path $dockerDir) {
            try {
                Remove-Item $dockerDir -Recurse -Force -ErrorAction Stop
                Write-Log "  Removed $dockerRel for $uname" 'OK'
            } catch {
                Write-Log "  Could not remove $dockerRel for ${uname}: $_" 'WARN'
            }
        }
    }

    # Remove per-user Terraform data directories
    foreach ($tfRel in @('AppData\Roaming\terraform.d', 'AppData\Roaming\HashiCorp')) {
        $tfDir = Join-Path $prof $tfRel
        if (Test-Path $tfDir) {
            try {
                Remove-Item $tfDir -Recurse -Force -ErrorAction Stop
                Write-Log "  Removed $tfRel for $uname" 'OK'
            } catch {
                Write-Log "  Could not remove $tfRel for ${uname}: $_" 'WARN'
            }
        }
    }

    # Remove the Master Electronics snippet from PowerShell profiles
    foreach ($relPath in @('Documents\PowerShell\profile.ps1', 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) {
        $psProfile = Join-Path $prof $relPath
        if (Test-Path $psProfile) {
            $content = Get-Content $psProfile -Raw
            # Strip the block we added (between the two sentinel comment lines)
            $cleaned = $content -replace '(?s)\r?\n# ── Master Electronics DevSetup PATH additions.*?# ──────────────────────────────────────────────────────────────────────────\r?\n', ''
            if ($cleaned -ne $content) {
                Set-Content $psProfile -Value $cleaned.TrimEnd() -Encoding UTF8
                Write-Log "  Removed PATH snippet from $relPath" 'OK'
            }
        }
    }

    # Remove all desktop shortcuts we created
    foreach ($lnkName in @('Developer Setup Guide', 'Visual Studio Code', 'Git Bash')) {
        $lnk = Join-Path $prof "Desktop\$lnkName.lnk"
        if (Test-Path $lnk) {
            Remove-Item $lnk -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed '$lnkName' shortcut for $uname" 'OK'
        }
    }

    # Remove per-user npm global directory (created by Configure-UserEnvironment.ps1)
    $npmGlobalDir = Join-Path $prof 'AppData\Roaming\npm'
    if (Test-Path $npmGlobalDir) {
        try {
            Remove-Item $npmGlobalDir -Recurse -Force -ErrorAction Stop
            Write-Log "  Removed npm global dir for $uname" 'OK'
        } catch {
            Write-Log "  Could not remove npm global dir for ${uname}: $_" 'WARN'
        }
    }

    # Remove npm global from user PATH registry (load hive)
    $npmGlobal  = Join-Path $prof 'AppData\Roaming\npm'
    $hivePath   = Join-Path $prof 'NTUSER.DAT'
    $hiveKey    = "HKU\METemp_$uname"

    try {
        & reg load $hiveKey $hivePath 2>&1 | Out-Null
        $regPath = "Registry::HKEY_USERS\METemp_$uname\Environment"

        # If reg load failed (NTUSER.DAT locked — user has an active session), fall back to
        # the already-loaded SID-based HKU path so we can still clean their PATH.
        if (-not (Test-Path "Registry::HKEY_USERS\METemp_$uname")) {
            $sid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' `
                        -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProfileImagePath -ieq $prof } |
                    Select-Object -First 1).PSChildName
            $regPath = if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
                "Registry::HKEY_USERS\$sid\Environment"
            } else {
                $null
            }
        }

        if ($regPath) {
            $pathProp   = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            $currentVal = if ($pathProp -and $pathProp.PSObject.Properties['Path']) { $pathProp.PSObject.Properties['Path'].Value } else { '' }
            if ($currentVal -like "*$npmGlobal*") {
                $parts  = $currentVal -split ';' | Where-Object { $_ -and $_ -ne $npmGlobal }
                $newVal = $parts -join ';'
                Set-ItemProperty -Path $regPath -Name Path -Value $newVal -Type ExpandString
                Write-Log "  Removed npm global from user PATH for $uname" 'OK'
            }
        }
    } catch {
        Write-Log "  Could not clean user PATH for ${uname}: $_" 'WARN'
    } finally {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg unload $hiveKey 2>&1 | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Unregister scheduled task
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Removing scheduled task ===' 'INFO'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Scheduled task '$TaskName' removed." 'OK'
} else {
    Write-Log "Task '$TaskName' not found — already removed." 'DIAG'
}

# ─────────────────────────────────────────────────────────────────────────────
# Chocolatey — uninstall if this script installed it
# ─────────────────────────────────────────────────────────────────────────────
if ($manifest.ChocolateyInstalled -eq $true) {
    Write-Log '' 'INFO'
    Write-Log '=== Uninstalling Chocolatey ===' 'INFO'
    $chocoDir = [System.Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    if (-not $chocoDir) { $chocoDir = 'C:\ProgramData\chocolatey' }
    if (Test-Path $chocoDir) {
        try {
            Remove-Item $chocoDir -Recurse -Force -ErrorAction Stop
            Write-Log "  Removed Chocolatey directory: $chocoDir" 'OK'
        } catch {
            Write-Log "  Could not remove Chocolatey directory: $_" 'WARN'
            $errors.Add("Could not remove Chocolatey automatically.")
        }
    }
    [System.Environment]::SetEnvironmentVariable('ChocolateyInstall',        $null, 'Machine')
    [System.Environment]::SetEnvironmentVariable('ChocolateyLastPathUpdate',  $null, 'Machine')
    [System.Environment]::SetEnvironmentVariable('ChocolateyToolsLocation',   $null, 'Machine')
    $mp    = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $newMp = ($mp -split ';' | Where-Object { $_ -and $_ -notlike '*chocolatey*' }) -join ';'
    if ($newMp -ne $mp) {
        [System.Environment]::SetEnvironmentVariable('Path', $newMp, 'Machine')
        Write-Log '  Removed Chocolatey from machine PATH.' 'OK'
    }
} else {
    Write-Log 'Chocolatey was pre-existing — leaving it in place.' 'DIAG'
}

# ─────────────────────────────────────────────────────────────────────────────
# Force cleanup — remove any tool remnants still present after uninstall attempts
# Catches anything winget/choco left behind: directories, env vars, PATH entries.
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Force cleanup of tool remnants ===' 'INFO'

# Refresh PATH so Get-Command reflects what uninstalls actually removed
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# Known installation directories to remove if tools are still present
$fcNvmHome   = [System.Environment]::GetEnvironmentVariable('NVM_HOME',          'Machine'); if (-not $fcNvmHome)   { $fcNvmHome   = 'C:\ProgramData\nvm' }
$fcNvmLink   = [System.Environment]::GetEnvironmentVariable('NVM_SYMLINK',       'Machine'); if (-not $fcNvmLink)   { $fcNvmLink   = 'C:\Program Files\nodejs' }
$fcChocoDir  = [System.Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine'); if (-not $fcChocoDir)  { $fcChocoDir  = 'C:\ProgramData\chocolatey' }

$forceRemove = @(
    @{ Cmd = 'terraform'; Dir = 'C:\Program Files\Terraform'             }
    @{ Cmd = 'nvm';       Dir = $fcNvmHome                               }
    @{ Cmd = 'node';      Dir = $fcNvmLink                               }
    @{ Cmd = 'choco';     Dir = $fcChocoDir                              }
    # Python: choco installs to C:\Python312, winget/direct installs to C:\Program Files\Python312
    @{ Cmd = 'python';    Dir = 'C:\Python312'                           }
    @{ Cmd = 'python';    Dir = 'C:\Program Files\Python312'             }
    # Machine npm prefix — explicitly set by Install-DevEnvironment.ps1
    @{ Cmd = '';          Dir = 'C:\ProgramData\npm'                     }
    # Docker data directories left behind by the Docker uninstaller
    @{ Cmd = 'docker';    Dir = 'C:\ProgramData\DockerDesktop'           }
    @{ Cmd = 'docker';    Dir = 'C:\ProgramData\Docker'                  }
    # Tool install directories — removed if uninstaller left them behind
    @{ Cmd = 'git';       Dir = 'C:\Program Files\Git'                   }
    @{ Cmd = 'pwsh';      Dir = 'C:\Program Files\PowerShell'            }
    @{ Cmd = 'gh';        Dir = 'C:\Program Files\GitHub CLI'            }
    @{ Cmd = 'code';      Dir = 'C:\Program Files\Microsoft VS Code'     }
    @{ Cmd = 'aws';       Dir = 'C:\Program Files\Amazon'                }
)

foreach ($item in $forceRemove) {
    if ($item.Dir -and (Test-Path $item.Dir)) {
        try {
            Remove-Item $item.Dir -Recurse -Force -ErrorAction Stop
            Write-Log "  Force removed: $($item.Dir)" 'OK'
        } catch {
            Write-Log "  Could not force remove $($item.Dir): $_" 'WARN'
        }
    }
}

# Unconditionally scrub HKLM Windows Uninstall registry entries for all managed tools.
# Ghost entries in Programs & Features block choco from reinstalling (it sees
# "already latest") and show up as installed even after files are gone.
# Note: Python Launcher has a dedicated Invoke-RegistryUninstall call below — exclude
# it here so its uninstaller still runs before we clean up its key.
$managedUninstallPatterns = @(
    '*Visual Studio Code*'
    '*Git version*'
    '*Git*'
    '*PowerShell*7*'
    '*GitHub CLI*'
    '*Node.js*'
    '*Python 3.*'
    '*AWS Command Line Interface*'
    '*Terraform*'
    '*Docker Desktop*'
)
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($pattern in $managedUninstallPatterns) {
    foreach ($root in $uninstallRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $e  = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            $dn = if ($e -and $e.PSObject.Properties['DisplayName']) { $e.PSObject.Properties['DisplayName'].Value } else { $null }
            if ($dn -and $dn -like $pattern) {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed HKLM registry entry: $dn" 'DIAG'
            }
        }
    }
}

# Also scan user registry hives — VS Code user-scoped installs register under
# HKCU, not HKLM, so the HKLM pass above misses them entirely.
$skipHiveUsers = @('systemprofile','LocalService','NetworkService','defaultuser0','Default','All Users','Public')
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skipHiveUsers -and (Test-Path (Join-Path $_.FullName 'NTUSER.DAT')) } |
    ForEach-Object {
        $uname    = $_.Name
        $hivePath = Join-Path $_.FullName 'NTUSER.DAT'
        $hiveKey  = "HKU\MEClean_$uname"
        try {
            & reg load $hiveKey $hivePath 2>&1 | Out-Null
            $hkuUninstall = "Registry::HKEY_USERS\MEClean_$uname\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            if (Test-Path $hkuUninstall) {
                foreach ($pattern in $managedUninstallPatterns) {
                    Get-ChildItem $hkuUninstall -ErrorAction SilentlyContinue | ForEach-Object {
                        $e  = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                        $dn = if ($e -and $e.PSObject.Properties['DisplayName']) { $e.PSObject.Properties['DisplayName'].Value } else { $null }
                        if ($dn -and $dn -like $pattern) {
                            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                            Write-Log "  Removed HKCU registry entry ($uname): $dn" 'DIAG'
                        }
                    }
                }
            }
        } catch {
            Write-Log "  Could not scan user hive for ${uname}: $_" 'WARN'
        } finally {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg unload $hiveKey 2>&1 | Out-Null
        }
    }

# Clean nvm / nodejs env vars
foreach ($var in @('NVM_HOME','NVM_SYMLINK')) {
    if ([System.Environment]::GetEnvironmentVariable($var, 'Machine')) {
        [System.Environment]::SetEnvironmentVariable($var, $null, 'Machine')
        Write-Log "  Cleared machine env var: $var" 'OK'
    }
}

# Clean Chocolatey env vars
foreach ($var in @('ChocolateyInstall','ChocolateyLastPathUpdate','ChocolateyToolsLocation')) {
    if ([System.Environment]::GetEnvironmentVariable($var, 'Machine')) {
        [System.Environment]::SetEnvironmentVariable($var, $null, 'Machine')
        Write-Log "  Cleared machine env var: $var" 'OK'
    }
}

# Remove managed entries from machine PATH
$mp = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($mp) {
    $cleaned = ($mp -split ';' | Where-Object {
        $_ -and
        $_ -notlike '*chocolatey*'               -and
        $_ -notlike '*\nvm*'                     -and
        $_ -notlike '*\nodejs*'                  -and
        $_ -notlike '*Terraform*'                -and
        $_ -notlike '*systemprofile*AppData*npm*' -and
        $_ -notlike '*\ProgramData\npm*'
    }) -join ';'
    if ($cleaned -ne $mp) {
        [System.Environment]::SetEnvironmentVariable('Path', $cleaned, 'Machine')
        Write-Log '  Removed managed entries from machine PATH.' 'OK'
    }
}

# For tools still on PATH, try choco first (more reliable for choco-installed packages),
# then fall back to winget.
$stragglers = @(
    @{ Cmd = 'git';       Id = 'Git.Git';                    ChocoId = 'git';             DisplayName = 'Git*'                          }
    @{ Cmd = 'code';      Id = 'Microsoft.VisualStudioCode'; ChocoId = 'vscode';          DisplayName = 'Microsoft Visual Studio Code*' }
    @{ Cmd = 'gh';        Id = 'GitHub.cli';                 ChocoId = 'gh';              DisplayName = 'GitHub CLI*'                   }
    @{ Cmd = 'node';      Id = 'OpenJS.NodeJS';              ChocoId = 'nodejs';          DisplayName = 'Node.js*'                      }
    @{ Cmd = 'python';    Id = 'Python.Python.3.12';         ChocoId = 'python312';       DisplayName = 'Python 3.1*'                   }
    @{ Cmd = 'aws';       Id = 'Amazon.AWSCLI';              ChocoId = 'awscli';          DisplayName = 'AWS Command Line Interface*'   }
    @{ Cmd = 'pwsh';      Id = 'Microsoft.PowerShell';       ChocoId = 'powershell-core'; DisplayName = 'PowerShell *'                  }
    @{ Cmd = 'terraform'; Id = 'Hashicorp.Terraform';        ChocoId = 'terraform';       DisplayName = 'Terraform*'                    }
)

foreach ($s in $stragglers) {
    if (Get-Command $s.Cmd -ErrorAction SilentlyContinue) {
        $stragRemoved = $false

        # Try choco first
        if ($s.ChocoId -and (Get-Command choco -ErrorAction SilentlyContinue)) {
            $chocoId  = $s.ChocoId
            $maxTries = 3
            for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
                Write-Log "  $($s.Cmd) still present — retrying choco uninstall $chocoId…" 'DIAG'
                $job = Start-Job -ScriptBlock {
                    $out = & choco uninstall $args[0] --yes --no-progress 2>&1
                    [PSCustomObject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
                } -ArgumentList $chocoId
                $done = Wait-Job $job -Timeout 120
                if (-not $done) {
                    Stop-Job $job; Remove-Job $job -Force
                    Write-Log "  Force choco uninstall timed out for $chocoId." 'WARN'
                    break
                }
                $r = Receive-Job $job; Remove-Job $job -Force
                if ($r.ExitCode -eq 0) {
                    Write-Log "  Force choco uninstall OK: $chocoId" 'OK'
                    $stragRemoved = $true
                    break
                } elseif ($r.ExitCode -eq 1618) {
                    Write-Log "  Force choco exit 1618 (MSI lock) — waiting 20s before retry ($attempt/$maxTries)…" 'WARN'
                    if ($attempt -lt $maxTries) { Start-Sleep -Seconds 20 }
                } else {
                    Write-Log "  Force choco exit $($r.ExitCode) for $chocoId." 'DIAG'
                    break
                }
            }
        }

        # Registry uninstall — reads HKLM uninstall entry and invokes installer
        # directly.  More reliable than winget under SYSTEM (no WinRT dependency).
        if (-not $stragRemoved -and $s.DisplayName) {
            $stragRemoved = Invoke-RegistryUninstall -DisplayNamePattern $s.DisplayName
            if ($stragRemoved) { Write-Log "  Registry uninstall OK for $($s.Cmd)." 'OK' }
        }

        if (-not $stragRemoved) {
            Write-Log "  $($s.Cmd) still present — retrying winget uninstall $($s.Id)…" 'DIAG'
            $job = Start-Job -ScriptBlock {
                $out = & winget uninstall --id $args[0] --silent --accept-source-agreements 2>&1
                [PSCustomObject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
            } -ArgumentList $s.Id
            $done = Wait-Job $job -Timeout 120
            if ($done) {
                $r = Receive-Job $job; Remove-Job $job -Force
                if ($r.ExitCode -eq 0) { Write-Log "  Force uninstall OK: $($s.Id)" 'OK' }
                else { Write-Log "  Force uninstall could not remove $($s.Id) — manual removal may be needed." 'WARN' }
            } else {
                Stop-Job $job; Remove-Job $job -Force
                Write-Log "  Force uninstall timed out for $($s.Id)." 'WARN'
            }
        }
    }
}

# Python Launcher — installed as a separate MSI by the Python 3.12 installer.
# Lives in C:\Windows\py.exe so it's always on PATH and skipped by the straggler
# cmd-presence check above. Target it directly via registry uninstall.
Write-Log '' 'INFO'
Write-Log '=== Removing Python Launcher ===' 'INFO'
$pyLauncherRemoved = Invoke-RegistryUninstall -DisplayNamePattern '*Python Launcher*'
if ($pyLauncherRemoved) {
    Write-Log '  Python Launcher removed.' 'OK'
} else {
    Write-Log '  Python Launcher not found in registry — already removed or never installed.' 'DIAG'
}

# ─────────────────────────────────────────────────────────────────────────────
# Remove setup directory and all remaining install artifacts
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Removing setup directory ===' 'INFO'
if (Test-Path $SetupDir) {
    # Preserve install.log before wiping the directory — it's the only log inside
    # SetupDir; all others (rollback.log, verify-*.log) already live in the parent.
    $installLogSrc = Join-Path $SetupDir 'install.log'
    if (Test-Path $installLogSrc) {
        $installLogDest = Join-Path (Split-Path $SetupDir -Parent) 'install.log'
        Copy-Item $installLogSrc $installLogDest -Force -ErrorAction SilentlyContinue
        Write-Log "Preserved install.log to: $installLogDest" 'OK'
    }

    try {
        Remove-Item $SetupDir -Recurse -Force -ErrorAction Stop
        Write-Log "Removed: $SetupDir" 'OK'
    } catch {
        Write-Log "Could not remove $SetupDir : $_" 'WARN'
    }
}

# Remove the Anthropic API key stored as a machine env var by Deploy-SetupChatbot
$apiKey = [System.Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'Machine')
if ($apiKey) {
    [System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $null, 'Machine')
    Write-Log 'Removed ANTHROPIC_API_KEY machine environment variable.' 'OK'
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Desktop shortcuts — VS Code installer drops one here for all users
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Removing Public Desktop shortcuts ===' 'INFO'
foreach ($lnkName in @('Visual Studio Code', 'Git Bash', 'Developer Setup Guide')) {
    $lnk = "C:\Users\Public\Desktop\$lnkName.lnk"
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Write-Log "  Removed Public Desktop shortcut: $lnkName" 'OK'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp download file cleanup — ME_*.exe/msi/zip left in SYSTEM temp on failure
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log '=== Cleaning up temp download files ===' 'INFO'
$tempDirs = @(
    $env:TEMP,
    'C:\Users\Default\AppData\Local\Temp',
    'C:\Windows\Temp'
)
foreach ($td in $tempDirs) {
    if (Test-Path $td) {
        Get-ChildItem $td -Filter 'ME_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed temp file: $($_.FullName)" 'OK'
        }
    }
}

# Chocolatey temp leftovers — choco writes per-session cache to AppData\Local\Temp\chocolatey
# Clean this for all user profiles and for the SYSTEM/Windows temp location.
$skipProfiles = @('systemprofile','LocalService','NetworkService','defaultuser0','Default','All Users','Public')
$chocoTempDirs = @('C:\Windows\Temp\chocolatey') +
    (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
     Where-Object { $_.Name -notin $skipProfiles } |
     ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp\chocolatey' })
foreach ($ct in $chocoTempDirs) {
    if (Test-Path $ct) {
        Remove-Item $ct -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "  Removed chocolatey temp: $ct" 'OK'
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# Verification report — confirm each tool is actually gone
# ─────────────────────────────────────────────────────────────────────────────
$verifyLog = Join-Path (Split-Path $SetupDir -Parent) 'verify-rollback.log'
$verifyTs  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$toolChecks = @(
    @{ Label = 'Git';          Cmd = 'git'       }
    @{ Label = 'VS Code';      Cmd = 'code'      }
    @{ Label = 'PowerShell 7'; Cmd = 'pwsh'      }
    @{ Label = 'nvm';          Cmd = 'nvm'       }
    @{ Label = 'Node.js';      Cmd = 'node'      }
    @{ Label = 'npm';          Cmd = 'npm'       }
    @{ Label = 'Claude Code';  Cmd = 'claude'    }
    @{ Label = 'GitHub CLI';   Cmd = 'gh'        }
    @{ Label = 'Docker';       Cmd = 'docker'    }
    @{ Label = 'Python';       Cmd = 'python'    }
    @{ Label = 'AWS CLI';      Cmd = 'aws'       }
    @{ Label = 'Terraform';    Cmd = 'terraform' }
)

$verifyLines = @("=== ROLLBACK VERIFICATION  $verifyTs ===")
$stillPresent = 0

Write-Log '' 'INFO'
Write-Log ('─' * 64) 'INFO'
Write-Log '  TOOL REMOVAL VERIFICATION' 'INFO'
Write-Log ('─' * 64) 'INFO'

# Clear PowerShell's command cache so removals are reflected
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

foreach ($c in $toolChecks) {
    $cmd = Get-Command $c.Cmd -ErrorAction SilentlyContinue
    # Windows 11 App Execution Aliases (e.g. the python Store stub) live under WindowsApps
    # and are pre-existing — not installed by us.  Treat them as absent so they don't
    # produce a false "STILL PRESENT" after a successful uninstall.
    $present = $cmd -and ($cmd.Source -notlike '*\WindowsApps\*')
    if ($present) {
        $row = "  {0,-15} STILL PRESENT" -f $c.Label
        Write-Log $row 'WARN'
        $verifyLines += $row
        $stillPresent++
    } else {
        $row = "  {0,-15} removed" -f $c.Label
        Write-Log $row 'OK'
        $verifyLines += $row
    }
}

$verifyLines += "  ─────────────────────────────────────────────────────"
$verifyLines += "  Removed: $($toolChecks.Count - $stillPresent)   Still present: $stillPresent"
$verifyLines += "=== END ==="
$verifyLines | Set-Content $verifyLog -Encoding UTF8
Write-Log ('─' * 64) 'INFO'
Write-Log "Verification report saved: $verifyLog" 'INFO'

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Log '' 'INFO'
Write-Log ('=' * 64) 'INFO'
Write-Log '  ROLLBACK COMPLETE' 'INFO'
Write-Log ('=' * 64) 'INFO'

if ($errors.Count -gt 0) {
    Write-Log 'Items requiring manual attention:' 'WARN'
    foreach ($e in $errors) { Write-Log "  * $e" 'WARN' }
    exit 1
}

Write-Log 'All items removed successfully.' 'OK'
exit 0


















