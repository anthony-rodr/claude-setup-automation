$ErrorActionPreference = 'Stop'
$Root   = 'C:\ProgramData\MasterElectronics'
$LogDir = Join-Path $Root 'Logs'

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp       = Join-Path $LogDir 'Deploy-DevEnvironment.ps1'
$NinjaLog  = Join-Path $LogDir "ninja-deploy-$stamp.log"
$DeployOut = Join-Path $LogDir "deploy-output-$stamp.log"

function Write-NinjaLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $NinjaLog -Value $line -Encoding UTF8
    Write-Host $line
}

try {
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
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"") `
        -RedirectStandardOutput $DeployOut `
        -NoNewWindow -PassThru
    $completed = $proc.WaitForExit(90 * 60 * 1000)
    if ($completed) { $proc.WaitForExit() }  # flush exit code on PS 5.1
    if (-not $completed) {
        try { $proc.Kill() } catch {}
        Write-NinjaLog 'Deploy timed out after 90 minutes and was killed.'
        exit 1
    }
    $exitCode = $proc.ExitCode
    if ($null -eq $exitCode) { $exitCode = 0 }
    $duration = (Get-Date) - $startTime
    Write-NinjaLog ("Install finished in {0}m {1}s. Exit code: {2}" -f [int]$duration.TotalMinutes, $duration.Seconds, $exitCode)

    # ── Summary: pull verification table + failures from install.log ──────────
    $installLog = Join-Path $Root 'DevSetup\install.log'
    if (Test-Path $installLog) {
        $lines = Get-Content $installLog -ErrorAction SilentlyContinue

        Write-Host ''
        Write-Host '========== TOOL VERIFICATION =========='
        $lines | Where-Object { $_ -match '\[(OK|FAIL|WARN)\]\s+\w' } |
            Select-Object -Last 25 |
            ForEach-Object { Write-Host $_ }

        $failLines = @($lines | Where-Object { $_ -match '\[FAIL\]' })
        Write-Host ''
        Write-Host '========== FAILURES ==================='
        if ($failLines.Count -gt 0) {
            $failLines | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host 'None.'
        }
        Write-Host '======================================='
    } else {
        Write-NinjaLog "WARNING: install.log not found at $installLog"
    }

    Write-NinjaLog "Full install log : $installLog"
    Write-NinjaLog "Full deploy output: $DeployOut"

    exit $exitCode

} catch {
    Write-NinjaLog "Bootstrap failed: $($_.Exception.Message)"
    Write-Host ''
    if (Test-Path $NinjaLog) { Get-Content $NinjaLog -Tail 40 }
    exit 1
}
