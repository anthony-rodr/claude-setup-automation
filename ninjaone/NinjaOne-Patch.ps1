# PatchUrl is injected by NinjaOne as a Script Variable (environment variable).
# Do NOT add a param() block — NinjaOne does not pass CLI args; it injects env vars.
$PatchUrl = ($env:patchurl).Trim()
$ErrorActionPreference = 'Stop'
if (-not $PatchUrl) { throw 'patchurl script variable is not set. Configure it in the NinjaOne automation script variables.' }
$Root   = 'C:\ProgramData\AIE'
$LogDir = Join-Path $Root 'Logs'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp        = Join-Path $LogDir 'Patch-DevEnvironment.ps1'
$NinjaLog   = Join-Path $LogDir "ninja-patch-$stamp.log"
$PatchOut   = Join-Path $LogDir "patch-output-$stamp.log"
$PatchErr   = Join-Path $LogDir "patch-error-$stamp.log"
$SummaryLog = Join-Path $Root 'patch-summary.log'

function Write-NinjaLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $NinjaLog -Value $line -Encoding UTF8
    Write-Host $line
}

# Use the same mutex as the full install so patch and install can't overlap.
$MutexName     = 'Global\AIE-DevEnvironment-Install'
$mutex         = New-Object System.Threading.Mutex($false, $MutexName)
$hasMutex      = $false
$finalExitCode = 1

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-NinjaLog 'An AIE environment install/patch is already running. Exiting.'
        $finalExitCode = 0
        return
    }

    Write-NinjaLog "Patch started. Computer: $env:COMPUTERNAME"
    Write-NinjaLog "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    Write-NinjaLog "Downloading patch script..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $dlHeaders = @{ 'User-Agent' = 'aie-dev-setup' }
    Invoke-WebRequest $PatchUrl -Headers $dlHeaders -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    Write-NinjaLog "Patch script downloaded. Checking for updates..."

    $startTime = Get-Date

    # Start-Process avoids pipeline-hang from any background jobs in the patch script.
    $procArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tmp)
    $proc = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $procArgs `
        -RedirectStandardOutput $PatchOut `
        -RedirectStandardError  $PatchErr `
        -NoNewWindow -PassThru

    # Stream patch output to NinjaOne Activity in real time (3-second poll).
    # Filter [DIAG] lines — too noisy for NinjaOne activity view.
    $lastPos   = 0
    $timeoutAt = (Get-Date).AddMinutes(60)

    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $timeoutAt) {
            try { $proc.Kill() } catch {}
            Write-NinjaLog 'Patch timed out after 60 minutes and was killed.'
            $finalExitCode = 1
            return
        }
        if (Test-Path $PatchOut) {
            try {
                $fs = [System.IO.File]::Open(
                    $PatchOut,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                [void]$fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin)
                $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                $chunk = $sr.ReadToEnd()
                if ($chunk.Length -gt 0) {
                    $lastPos = $fs.Position
                    $filtered = ($chunk -split "`r?`n" | Where-Object { $_ -notmatch '\]\[DIAG\]' }) -join "`n"
                    if ($filtered.Trim()) { Write-Host $filtered }
                }
                $sr.Dispose()
            } catch {}
        }
        Start-Sleep -Seconds 3
    }
    $proc.WaitForExit()  # flush exit code on PS 5.1
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = 0 }

    # Flush any output written after the last poll
    if (Test-Path $PatchOut) {
        try {
            $fs = [System.IO.File]::Open(
                $PatchOut,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            [void]$fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            if ($chunk.Length -gt 0) {
                $filtered = ($chunk -split "`r?`n" | Where-Object { $_ -notmatch '\]\[DIAG\]' }) -join "`n"
                if ($filtered.Trim()) { Write-Host $filtered }
            }
            $sr.Dispose()
        } catch {}
    }

    $duration = (Get-Date) - $startTime
    Write-NinjaLog ("Patch finished in {0}m {1}s. Exit code: {2}" -f [int]$duration.TotalMinutes, $duration.Seconds, $exitCode)

    # ── Summary output ──────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host '========== PATCH SUMMARY =========='
    if (Test-Path $SummaryLog) {
        Get-Content $SummaryLog | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "patch-summary.log not found at $SummaryLog"
    }

    Write-Host ''
    Write-Host '========== WARNINGS / FAILURES =========='
    if (Test-Path $PatchOut) {
        $warnFail = @(Get-Content $PatchOut -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '\[(WARN|FAIL)\]' })
        if ($warnFail.Count -gt 0) {
            $warnFail | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host 'None.'
        }
    }
    Write-Host '==================================='

    if (Test-Path $PatchErr) {
        $errTail = @(Get-Content $PatchErr -Tail 20 -ErrorAction SilentlyContinue)
        if ($errTail.Count -gt 0) {
            Write-Host ''
            Write-Host '========== STDERR TAIL ============'
            $errTail | ForEach-Object { Write-Host $_ }
            Write-Host '==================================='
        }
    }

    Write-NinjaLog "Full patch log   : $(Join-Path $Root 'patch.log')"
    Write-NinjaLog "Full patch output: $PatchOut"
    Write-NinjaLog "Full patch errors: $PatchErr"
    Write-NinjaLog ('=' * 64)
    if ($exitCode -eq 0) {
        Write-NinjaLog "RESULT: PATCH SUCCEEDED on $env:COMPUTERNAME"
    } else {
        Write-NinjaLog "RESULT: PATCH FAILED (exit $exitCode) on $env:COMPUTERNAME — see WARNINGS / FAILURES above"
    }
    Write-NinjaLog ('=' * 64)
    Write-NinjaLog "Bootstrap exiting with code $exitCode"

    $finalExitCode = $exitCode

} catch {
    Write-NinjaLog "Patch bootstrap failed: $($_.Exception.Message)"
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
