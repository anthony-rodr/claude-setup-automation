# Lambda URL is permanent — never needs updating in NinjaOne.
$LambdaUrl = 'https://dqjiychkx3ockgvn24rscxkmaq0wwfat.lambda-url.us-east-2.on.aws/'

# NinjaOne passes Script Variables as environment variables — no param() block.
$ApiKey = ($env:lambdakey).Trim()
$ErrorActionPreference = 'Stop'
if (-not $ApiKey) { throw 'lambdakey script variable is not configured in NinjaOne.' }

$Root   = 'C:\ProgramData\AIE'
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

function Get-LambdaPresignedUrl {
    param([string]$File)
    $r   = Invoke-WebRequest -Uri "${LambdaUrl}?file=$File" -Headers @{ 'x-api-key' = $ApiKey; 'User-Agent' = 'aie-dev-setup' } -UseBasicParsing -ErrorAction Stop
    $url = ($r.Content | ConvertFrom-Json).url
    if (-not $url) { throw "Lambda returned no URL for file=$File" }
    return $url
}

$MutexName     = 'Global\AIE-DevEnvironment-Install'
$mutex         = New-Object System.Threading.Mutex($false, $MutexName)
$hasMutex      = $false
$finalExitCode = 1

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-NinjaLog 'Another AIE Dev Environment install is already running. Exiting.'
        $finalExitCode = 0
        return
    }

    Write-NinjaLog "Bootstrap started. Computer: $env:COMPUTERNAME"
    Write-NinjaLog "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $dlHeaders = @{ 'User-Agent' = 'aie-dev-setup' }

    # Resolve fresh pre-signed S3 URLs from Lambda — no URL rotation needed in NinjaOne.
    Write-NinjaLog "Resolving download URLs via Lambda..."
    $VersionsUrl = Get-LambdaPresignedUrl 'versions'
    $DeployUrl   = Get-LambdaPresignedUrl 'deploy'
    $PackageUrl  = Get-LambdaPresignedUrl 'package'
    Write-NinjaLog "URLs resolved."

    # Fetch VERSIONS.md first to get the expected Deploy script hash before downloading it.
    Write-NinjaLog "Fetching VERSIONS.md for integrity check..."
    $versionsContent    = (Invoke-WebRequest $VersionsUrl -Headers $dlHeaders -UseBasicParsing -ErrorAction Stop).Content
    $expectedDeployHash = if ($versionsContent -match '(?m)DeploySHA256:\s*([a-fA-F0-9]{64})') { $Matches[1].ToLower() } else { $null }
    if (-not $expectedDeployHash) {
        throw 'DeploySHA256 not found in VERSIONS.md. Re-run Package-Release.ps1 and re-upload all S3 files before deploying.'
    }

    Write-NinjaLog "Downloading deploy script..."
    Invoke-WebRequest $DeployUrl -Headers $dlHeaders -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    $actualDeployHash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()
    if ($actualDeployHash -ne $expectedDeployHash) {
        throw "Deploy script integrity check FAILED.`nExpected: $expectedDeployHash`nActual  : $actualDeployHash"
    }
    Write-NinjaLog "Deploy script verified (SHA256 OK). Starting installer (this takes 15-20 min)..."

    $startTime = Get-Date

    # Start-Process avoids the pipeline-hang that occurs when Start-Job worker processes
    # spawned by Configure-ExistingProfiles hold stdout handles open after Deploy exits.
    $procArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tmp)
    if ($PackageUrl)  { $procArgs += @('-PackageUrl',  $PackageUrl)  }
    if ($VersionsUrl) { $procArgs += @('-VersionsUrl', $VersionsUrl) }
    $proc = Start-Process `
        -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $procArgs `
        -RedirectStandardOutput $DeployOut `
        -RedirectStandardError  $DeployErr `
        -NoNewWindow -PassThru
    # Stream deploy output to NinjaOne Activity in real time (3-second poll).
    # Uses FileShare.ReadWrite so the child process can keep writing while we read.
    $lastPos   = 0
    $timeoutAt = (Get-Date).AddMinutes(90)

    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $timeoutAt) {
            try { $proc.Kill() } catch {}
            Write-NinjaLog 'Deploy timed out after 90 minutes and was killed.'
            $finalExitCode = 1
            return
        }
        if (Test-Path $DeployOut) {
            try {
                $fs = [System.IO.File]::Open(
                    $DeployOut,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                [void]$fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin)
                $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                $chunk = $sr.ReadToEnd()
                if ($chunk.Length -gt 0) {
                    $lastPos = $fs.Position
                    # Filter [DIAG] lines — kept in log files, too noisy for NinjaOne activity view
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
    if (Test-Path $DeployOut) {
        try {
            $fs = [System.IO.File]::Open(
                $DeployOut,
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
    Write-NinjaLog ('=' * 64)
    if ($exitCode -eq 0) {
        Write-NinjaLog "RESULT: INSTALL SUCCEEDED on $env:COMPUTERNAME"
    } else {
        Write-NinjaLog "RESULT: INSTALL FAILED (exit $exitCode) on $env:COMPUTERNAME — see WARNINGS / FAILURES above"
    }
    Write-NinjaLog ('=' * 64)
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
