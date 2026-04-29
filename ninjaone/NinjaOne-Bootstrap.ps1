$ErrorActionPreference = 'Stop'
$Root   = 'C:\ProgramData\MasterElectronics'
$LogDir = Join-Path $Root 'Logs'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp       = Join-Path $LogDir 'Deploy-DevEnvironment.ps1'
$NinjaLog  = Join-Path $LogDir "ninja-deploy-$stamp.log"
$DeployOut = Join-Path $LogDir "deploy-output-$stamp.log"
$DeployErr = Join-Path $LogDir "deploy-error-$stamp.log"

function Write-NinjaLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $NinjaLog -Value $line -Encoding UTF8
    Write-Host $line
}

$MutexName     = 'Global\MasterElectronics-DevEnvironment-Install'
$mutex         = New-Object System.Threading.Mutex($false, $MutexName)
$hasMutex      = $false
$finalExitCode = 1

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-NinjaLog 'Another Master Electronics Dev Environment install is already running. Exiting.'
        $finalExitCode = 0
        return
    }

    Write-NinjaLog "Bootstrap started. Computer: $env:COMPUTERNAME"
    Write-NinjaLog "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $url = 'https://raw.githubusercontent.com/anthony-rodr/claude-setup-automation/main/scripts/Deploy-DevEnvironment.ps1'
    Write-NinjaLog "Downloading deploy script..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    Write-NinjaLog "Deploy script downloaded. Starting installer (this takes 15-20 min)..."

    $startTime = Get-Date

    # Start-Process avoids the pipeline-hang that occurs when Start-Job worker processes
    # spawned by Configure-ExistingProfiles hold stdout handles open after Deploy exits.
    $procArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tmp)
    $proc = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $procArgs `
        -RedirectStandardOutput $DeployOut `
        -RedirectStandardError  $DeployErr `
        -NoNewWindow -PassThru
    $completed = $proc.WaitForExit(90 * 60 * 1000)
    if ($completed) { $proc.WaitForExit() }  # flush exit code on PS 5.1
    if (-not $completed) {
        try { $proc.Kill() } catch {}
        Write-NinjaLog 'Deploy timed out after 90 minutes and was killed.'
        $finalExitCode = 1
        return
    }
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = 0 }
    $duration = (Get-Date) - $startTime
    Write-NinjaLog ("Install finished in {0}m {1}s. Exit code: {2}" -f [int]$duration.TotalMinutes, $duration.Seconds, $exitCode)

    # ── Summary: output clean verification reports ─────────────────────────────
    $verifyInstall   = Join-Path $Root 'verify-install.log'
    $verifyConfigure = Join-Path $Root 'verify-configure.log'
    $installLog      = Join-Path $Root 'DevSetup\install.log'

    Write-Host ''
    Write-Host '========== TOOL INSTALLATION =========='
    if (Test-Path $verifyInstall) {
        Get-Content $verifyInstall | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "verify-install.log not found at $verifyInstall"
    }

    Write-Host ''
    Write-Host '========== USER PROFILE CONFIG =========='
    if (Test-Path $verifyConfigure) {
        Get-Content $verifyConfigure | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "verify-configure.log not found at $verifyConfigure"
    }

    Write-Host ''
    Write-Host '========== WARNINGS / FAILURES =========='
    if (Test-Path $installLog) {
        $warnFail = @(Get-Content $installLog -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\[.*\]\[(WARN|FAIL)\](?!\s+\[DIAG\])' })
        if ($warnFail.Count -gt 0) {
            $warnFail | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host 'None.'
        }
    } else {
        Write-Host "install.log not found at $installLog"
    }
    Write-Host '========================================='

    if (Test-Path $DeployErr) {
        $errTail = @(Get-Content $DeployErr -Tail 20 -ErrorAction SilentlyContinue)
        if ($errTail.Count -gt 0) {
            Write-Host ''
            Write-Host '========== STDERR TAIL ================'
            $errTail | ForEach-Object { Write-Host $_ }
            Write-Host '======================================='
        }
    }

    Write-NinjaLog "Full install log   : $installLog"
    Write-NinjaLog "Full deploy output : $DeployOut"
    Write-NinjaLog "Full deploy errors : $DeployErr"
    Write-NinjaLog "Bootstrap exiting with code $exitCode"

    $finalExitCode = $exitCode

} catch {
    Write-NinjaLog "Bootstrap failed: $($_.Exception.Message)"
    Write-Host ''
    if (Test-Path $NinjaLog) { Get-Content $NinjaLog -Tail 40 }
    $finalExitCode = 1
} finally {
    [Console]::Out.Flush()
    [Console]::Error.Flush()
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

exit $finalExitCode
