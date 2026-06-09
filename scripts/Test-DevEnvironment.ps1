<#
.SYNOPSIS
    Master Electronics Dev Environment - Health Check

.DESCRIPTION
    Verifies that the Master Electronics dev environment is correctly installed
    and configured on the target machine. Designed to be run from NinjaOne as
    SYSTEM. All output is plain text written to stdout so it surfaces in NinjaOne
    Activity Logs.

    Sections:
      1.  Tool presence + version probe (each tool actually invoked)
      2.  PATH resolution (does the command resolve from machine PATH?)
      3.  Functional probes (Python stdlib, pip, npm registry, Docker daemon)
      4.  Network reachability TCP (PyPI, npmjs, marketplace, GitHub, Anthropic)
      4b. Zscaler / TLS configuration (NODE_EXTRA_CA_CERTS, PIP_CERT, live TLS)
      5.  Machine PATH content
      6.  Install manifest
      7.  Setup directory contents
      8.  Per-user configuration state
      9.  Logon scheduled task

    Exit codes:
      0 = no failures (warnings allowed)
      1 = one or more checks failed

.NOTES
    Run as SYSTEM from NinjaOne. Read-only — makes no changes to the machine.

    NinjaOne setup:
      Script type:        PowerShell
      Run As:             System
      Architecture:       64-bit
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$Results = [System.Collections.Generic.List[object]]::new()

function Add-CheckResult {
    param(
        [Parameter(Mandatory)] [string]$Category,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [ValidateSet('OK','WARN','FAIL','INFO')] [string]$Status,
        [string]$Detail = ''
    )
    $Results.Add([PSCustomObject]@{
        Category = $Category
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
    })
}

function Invoke-WithTimeout {
    <#
        Runs a scriptblock in a background job with a hard timeout.
        Returns @{ Output = string; ExitCode = int; TimedOut = bool }
        Used to keep pathological commands (docker info, wsl --status on broken
        kernel) from hanging the whole health check.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock]$Script,
        [int]$TimeoutSeconds = 15
    )
    $job = Start-Job -ScriptBlock $Script
    $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $finished) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{ Output = ''; ExitCode = -1; TimedOut = $true }
    }
    $output = (Receive-Job -Job $job 2>&1 | Out-String).Trim()
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return @{ Output = $output; ExitCode = 0; TimedOut = $false }
}

function Test-ToolVersion {
    <#
        Executes the tool with its version flag and captures actual output.
        FAIL if the file is missing, the call throws, or the output is empty.
        OK if the call succeeds and produces stdout.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ExePath,
        [string[]]$VersionArgs = @('--version'),
        [string]$ExpectedPattern = '',
        [string]$Category = 'Tool Versions'
    )
    if (-not (Test-Path -LiteralPath $ExePath)) {
        Add-CheckResult -Category $Category -Name $Name -Status 'FAIL' `
            -Detail "Not found at $ExePath"
        return
    }
    try {
        $verRaw = & $ExePath @VersionArgs 2>&1
        $verStr = ($verRaw | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($verStr)) {
            Add-CheckResult -Category $Category -Name $Name -Status 'FAIL' `
                -Detail 'Tool ran but produced no output'
            return
        }
        $firstLine = $verStr.Split("`n")[0].Trim()
        if ($ExpectedPattern -and $verStr -notmatch $ExpectedPattern) {
            Add-CheckResult -Category $Category -Name $Name -Status 'WARN' `
                -Detail "Output did not match '$ExpectedPattern': $firstLine"
            return
        }
        Add-CheckResult -Category $Category -Name $Name -Status 'OK' -Detail $firstLine
    } catch {
        Add-CheckResult -Category $Category -Name $Name -Status 'FAIL' `
            -Detail "Invocation threw: $($_.Exception.Message)"
    }
}

function Test-CommandResolvesOnPath {
    <#
        Verifies that a bare command name resolves from machine PATH.
        Catches cases where the file exists at the expected location but isn't
        on PATH (so 'python' resolves to a Store stub or fails).
    #>
    param(
        [Parameter(Mandatory)] [string]$CommandName,
        [string]$ExpectedSourceContains = '',
        [string]$Category = 'PATH Resolution'
    )
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        Add-CheckResult -Category $Category -Name $CommandName -Status 'FAIL' `
            -Detail 'Not found on PATH'
        return
    }
    $source = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
    if ($ExpectedSourceContains -and $source -notlike "*$ExpectedSourceContains*") {
        Add-CheckResult -Category $Category -Name $CommandName -Status 'WARN' `
            -Detail "Resolves to unexpected location: $source"
    } else {
        Add-CheckResult -Category $Category -Name $CommandName -Status 'OK' -Detail $source
    }
}

function Test-NetEndpoint {
    param(
        [Parameter(Mandatory)] [string]$Host,
        [int]$Port = 443,
        [string]$Reason = '',
        [int]$TimeoutMs = 3000
    )
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($Host, $Port, $null, $null)
        $waited = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $waited) {
            $client.Close()
            Add-CheckResult -Category 'Network' -Name "$Host`:$Port" -Status 'FAIL' `
                -Detail "Timeout after ${TimeoutMs}ms ($Reason)"
            return
        }
        $client.EndConnect($iar) | Out-Null
        $client.Close()
        Add-CheckResult -Category 'Network' -Name "$Host`:$Port" -Status 'OK' -Detail $Reason
    } catch {
        Add-CheckResult -Category 'Network' -Name "$Host`:$Port" -Status 'FAIL' `
            -Detail "$Reason - $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
$startTime = Get-Date
Write-Host '================================================================'
Write-Host '  ME DEV ENVIRONMENT - HEALTH CHECK'
Write-Host "  Computer:  $env:COMPUTERNAME"
Write-Host "  Run as:    $([Environment]::UserName)"
Write-Host "  Time:      $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host '================================================================'

# ---------------------------------------------------------------------------
# 1. Tool versions (each tool actually invoked)
# ---------------------------------------------------------------------------
Test-ToolVersion -Name 'Git'           -ExePath 'C:\Program Files\Git\cmd\git.exe'                    -ExpectedPattern 'git version'
Test-ToolVersion -Name 'VS Code'       -ExePath 'C:\Program Files\Microsoft VS Code\bin\code.cmd'    -ExpectedPattern '\d+\.\d+\.\d+'
Test-ToolVersion -Name 'PowerShell 7'  -ExePath 'C:\Program Files\PowerShell\7\pwsh.exe'             -ExpectedPattern 'PowerShell'
Test-ToolVersion -Name 'nvm'           -ExePath 'C:\ProgramData\nvm\nvm.exe' -VersionArgs @('version') -ExpectedPattern '\d+\.\d+\.\d+'
Test-ToolVersion -Name 'Node.js'       -ExePath 'C:\Program Files\nodejs\node.exe'                  -ExpectedPattern '^v\d+\.'
Test-ToolVersion -Name 'npm'           -ExePath 'C:\ProgramData\npm\npm.cmd'                        -ExpectedPattern '^\d+\.'
Test-ToolVersion -Name 'Claude Code'   -ExePath 'C:\ProgramData\npm\claude.cmd'                     -ExpectedPattern '\d+\.\d+\.\d+'
Test-ToolVersion -Name 'Python 3.12'   -ExePath 'C:\Program Files\Python312\python.exe'             -ExpectedPattern 'Python 3\.\d+'
Test-ToolVersion -Name 'GitHub CLI'    -ExePath 'C:\Program Files\GitHub CLI\gh.exe'                -ExpectedPattern 'gh version'
Test-ToolVersion -Name 'AWS CLI v2'    -ExePath 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'          -ExpectedPattern 'aws-cli'
Test-ToolVersion -Name 'Terraform'     -ExePath 'C:\Program Files\Terraform\terraform.exe' -VersionArgs @('version') -ExpectedPattern 'Terraform v'
# Claude Desktop (MSIX provisioned, machine-wide)
try {
    $claudePkg = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object DisplayName -like '*Claude*' |
        Select-Object -First 1
    if ($claudePkg) {
        Add-CheckResult -Category 'Tool Versions' -Name 'Claude Desktop (MSIX)' -Status 'OK' `
            -Detail "v$($claudePkg.Version) provisioned"
    } else {
        Add-CheckResult -Category 'Tool Versions' -Name 'Claude Desktop (MSIX)' -Status 'FAIL' `
            -Detail 'Not provisioned'
    }
} catch {
    Add-CheckResult -Category 'Tool Versions' -Name 'Claude Desktop (MSIX)' -Status 'WARN' `
        -Detail "AppX query failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 2. PATH resolution — does the bare command resolve from machine PATH?
# ---------------------------------------------------------------------------
Test-CommandResolvesOnPath -CommandName 'git'        -ExpectedSourceContains 'Git\cmd'
Test-CommandResolvesOnPath -CommandName 'code'       -ExpectedSourceContains 'Microsoft VS Code'
Test-CommandResolvesOnPath -CommandName 'pwsh'       -ExpectedSourceContains 'PowerShell\7'
Test-CommandResolvesOnPath -CommandName 'nvm'        -ExpectedSourceContains 'nvm'
Test-CommandResolvesOnPath -CommandName 'node'       -ExpectedSourceContains 'nodejs'
Test-CommandResolvesOnPath -CommandName 'npm'        -ExpectedSourceContains 'npm'
Test-CommandResolvesOnPath -CommandName 'claude'     -ExpectedSourceContains 'npm'
Test-CommandResolvesOnPath -CommandName 'python'     -ExpectedSourceContains 'Python312'
Test-CommandResolvesOnPath -CommandName 'pip'        -ExpectedSourceContains 'Python312'
Test-CommandResolvesOnPath -CommandName 'gh'         -ExpectedSourceContains 'GitHub CLI'
Test-CommandResolvesOnPath -CommandName 'aws'        -ExpectedSourceContains 'AWSCLIV2'
Test-CommandResolvesOnPath -CommandName 'terraform'  -ExpectedSourceContains 'Terraform'

# ---------------------------------------------------------------------------
# 3. Functional probes — exercise the tool, not just check the version
# ---------------------------------------------------------------------------

# Python: import critical stdlib modules. Catches the "half-broken Store
# Python" state where python.exe runs but Lib\encodings is missing.
$pythonExe = 'C:\Program Files\Python312\python.exe'
if (Test-Path -LiteralPath $pythonExe) {
    $r = Invoke-WithTimeout -Script {
        & 'C:\Program Files\Python312\python.exe' -c "import encodings, ssl, json, hashlib; print('ok')" 2>&1
    } -TimeoutSeconds 10
    if ($r.TimedOut) {
        Add-CheckResult -Category 'Functional Probes' -Name 'Python stdlib import' -Status 'FAIL' -Detail 'Timed out'
    } elseif ($r.Output -match 'ok') {
        Add-CheckResult -Category 'Functional Probes' -Name 'Python stdlib import' -Status 'OK' -Detail 'encodings, ssl, json, hashlib all importable'
    } else {
        Add-CheckResult -Category 'Functional Probes' -Name 'Python stdlib import' -Status 'FAIL' -Detail $r.Output
    }

    # pip availability via -m form
    $r2 = Invoke-WithTimeout -Script {
        & 'C:\Program Files\Python312\python.exe' -m pip --version 2>&1
    } -TimeoutSeconds 10
    if ($r2.Output -match '^pip ') {
        Add-CheckResult -Category 'Functional Probes' -Name 'python -m pip' -Status 'OK' -Detail $r2.Output.Split("`n")[0]
    } else {
        Add-CheckResult -Category 'Functional Probes' -Name 'python -m pip' -Status 'FAIL' -Detail $r2.Output
    }
}

# npm: query global prefix to confirm it's writable and pointing at ProgramData
$npmCmd = 'C:\ProgramData\npm\npm.cmd'
if (Test-Path -LiteralPath $npmCmd) {
    $r = Invoke-WithTimeout -Script { & 'C:\ProgramData\npm\npm.cmd' config get prefix 2>&1 } -TimeoutSeconds 15
    if ($r.Output -match 'C:\\ProgramData\\npm') {
        Add-CheckResult -Category 'Functional Probes' -Name 'npm prefix' -Status 'OK' -Detail $r.Output.Trim()
    } else {
        Add-CheckResult -Category 'Functional Probes' -Name 'npm prefix' -Status 'WARN' -Detail "Unexpected prefix: $($r.Output)"
    }
}

# Claude Code: actually run --version and parse the version
$claudeCmd = 'C:\ProgramData\npm\claude.cmd'
if (Test-Path -LiteralPath $claudeCmd) {
    $r = Invoke-WithTimeout -Script { & 'C:\ProgramData\npm\claude.cmd' --version 2>&1 } -TimeoutSeconds 15
    if ($r.Output -match '\d+\.\d+\.\d+') {
        Add-CheckResult -Category 'Functional Probes' -Name 'Claude Code runs' -Status 'OK' -Detail $r.Output.Trim()
    } else {
        Add-CheckResult -Category 'Functional Probes' -Name 'Claude Code runs' -Status 'FAIL' -Detail $r.Output
    }
}

# Git config — useful but per-user. Just check if global config exists at all.
$gitExe = 'C:\Program Files\Git\cmd\git.exe'
if (Test-Path -LiteralPath $gitExe) {
    $r = Invoke-WithTimeout -Script { & 'C:\Program Files\Git\cmd\git.exe' config --system --list 2>&1 } -TimeoutSeconds 5
    if ($LASTEXITCODE -eq 0 -or $r.Output) {
        Add-CheckResult -Category 'Functional Probes' -Name 'Git system config readable' -Status 'OK' -Detail 'git config --system --list succeeded'
    } else {
        Add-CheckResult -Category 'Functional Probes' -Name 'Git system config readable' -Status 'WARN' -Detail $r.Output
    }
}

# ---------------------------------------------------------------------------
# 4. Network reachability — endpoints we know cause Zscaler issues
# ---------------------------------------------------------------------------
Test-NetEndpoint -Host 'github.com'                    -Reason 'git clone, gh CLI'
Test-NetEndpoint -Host 'registry.npmjs.org'            -Reason 'npm install'
Test-NetEndpoint -Host 'pypi.org'                      -Reason 'pip install'
Test-NetEndpoint -Host 'files.pythonhosted.org'        -Reason 'pip wheel downloads'
Test-NetEndpoint -Host 'marketplace.visualstudio.com'  -Reason 'VS Code extension install'
Test-NetEndpoint -Host 'api.anthropic.com'             -Reason 'Claude Code'
Test-NetEndpoint -Host 'releases.hashicorp.com'        -Reason 'Terraform downloads'

# ---------------------------------------------------------------------------
# 4b. Zscaler / TLS configuration
# ---------------------------------------------------------------------------
# These checks catch the "extensions/npm/pip fail with 'unable to get local
# issuer certificate' through Zscaler" failure mode. Node and Python don't
# read the Windows cert store - they need explicit cert env vars.
# ---------------------------------------------------------------------------

# Zscaler root cert in Windows trust store
$zscalerRoots = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match 'Zscaler' }
if ($zscalerRoots) {
    $count = ($zscalerRoots | Measure-Object).Count
    $earliestExpiry = ($zscalerRoots | Sort-Object NotAfter | Select-Object -First 1).NotAfter
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'Zscaler root in trust store' `
        -Status 'OK' -Detail "$count cert(s), earliest expiry $($earliestExpiry.ToString('yyyy-MM-dd'))"
} else {
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'Zscaler root in trust store' `
        -Status 'INFO' -Detail 'No Zscaler root cert found (machine may not be on Zscaler network)'
}

# Validate a PEM file: exists, non-empty, starts with BEGIN CERTIFICATE
function Test-PemFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ OK = $false; Reason = 'File not found' } }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt 100) { return @{ OK = $false; Reason = "Suspiciously small ($size bytes)" } }
    $firstLine = (Get-Content -LiteralPath $Path -TotalCount 1).Trim()
    if ($firstLine -ne '-----BEGIN CERTIFICATE-----') {
        return @{ OK = $false; Reason = "Bad PEM header: '$firstLine'" }
    }
    return @{ OK = $true; Reason = "$size bytes, valid PEM header" }
}

# NODE_EXTRA_CA_CERTS — required for VS Code marketplace, npm, Claude Code
$nodeMachine = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', 'Machine')
$nodeUser    = [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS', 'User')
if ($nodeMachine) {
    $pem = Test-PemFile -Path $nodeMachine
    if ($pem.OK) {
        Add-CheckResult -Category 'TLS / Zscaler' -Name 'NODE_EXTRA_CA_CERTS (Machine)' `
            -Status 'OK' -Detail "$nodeMachine - $($pem.Reason)"
    } else {
        Add-CheckResult -Category 'TLS / Zscaler' -Name 'NODE_EXTRA_CA_CERTS (Machine)' `
            -Status 'FAIL' -Detail "$nodeMachine - $($pem.Reason)"
    }
} elseif ($nodeUser) {
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'NODE_EXTRA_CA_CERTS' `
        -Status 'WARN' -Detail "Set at User scope only ($nodeUser) - other users on this machine will hit cert errors"
} else {
    $severity = if ($zscalerRoots) { 'FAIL' } else { 'WARN' }
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'NODE_EXTRA_CA_CERTS' `
        -Status $severity -Detail 'Not set - VS Code marketplace, npm, and Claude Code will fail TLS through Zscaler'
}

# PIP_CERT — required for pip install through Zscaler
$pipMachine = [Environment]::GetEnvironmentVariable('PIP_CERT', 'Machine')
$pipUser    = [Environment]::GetEnvironmentVariable('PIP_CERT', 'User')
if ($pipMachine) {
    $pem = Test-PemFile -Path $pipMachine
    if ($pem.OK) {
        Add-CheckResult -Category 'TLS / Zscaler' -Name 'PIP_CERT (Machine)' `
            -Status 'OK' -Detail "$pipMachine - $($pem.Reason)"
    } else {
        Add-CheckResult -Category 'TLS / Zscaler' -Name 'PIP_CERT (Machine)' `
            -Status 'FAIL' -Detail "$pipMachine - $($pem.Reason)"
    }
} elseif ($pipUser) {
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'PIP_CERT' `
        -Status 'WARN' -Detail "Set at User scope only ($pipUser)"
} else {
    $severity = if ($zscalerRoots) { 'WARN' } else { 'INFO' }
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'PIP_CERT' `
        -Status $severity -Detail 'Not set - pip install may fail with TLS errors through Zscaler'
}

# Standard Zscaler PEM file location
$standardPem = 'C:\ProgramData\ZscalerCA\zscaler-root-ca.pem'
$pem = Test-PemFile -Path $standardPem
if ($pem.OK) {
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'Standard PEM file' `
        -Status 'OK' -Detail "$standardPem - $($pem.Reason)"
} else {
    $severity = if ($zscalerRoots) { 'WARN' } else { 'INFO' }
    Add-CheckResult -Category 'TLS / Zscaler' -Name 'Standard PEM file' `
        -Status $severity -Detail "$standardPem - $($pem.Reason)"
}

# Live HTTPS handshake test — uses Windows trust store via .NET
# (catches "Zscaler intercept is broken at the network level")
$tlsProbeTargets = @(
    @{ Url = 'https://marketplace.visualstudio.com/'; Name = 'VS Code Marketplace TLS' },
    @{ Url = 'https://registry.npmjs.org/'           ; Name = 'npm Registry TLS' },
    @{ Url = 'https://pypi.org/'                     ; Name = 'PyPI TLS' }
)
foreach ($t in $tlsProbeTargets) {
    $probeBlock = [scriptblock]::Create("(Invoke-WebRequest -UseBasicParsing -Method Head -Uri '$($t.Url)' -TimeoutSec 8).StatusCode")
    $r = Invoke-WithTimeout -Script $probeBlock -TimeoutSeconds 12
    if ($r.TimedOut) {
        Add-CheckResult -Category 'TLS / Zscaler' -Name $t.Name -Status 'WARN' `
            -Detail "TLS probe timed out: $($t.Url)"
    } elseif ($r.Output -match '^\d+$' -and [int]$r.Output -lt 500) {
        Add-CheckResult -Category 'TLS / Zscaler' -Name $t.Name -Status 'OK' `
            -Detail "HTTP $($r.Output) from $($t.Url)"
    } else {
        Add-CheckResult -Category 'TLS / Zscaler' -Name $t.Name -Status 'FAIL' `
            -Detail "Probe failed: $($r.Output.Split("`n")[0])"
    }
}

# ---------------------------------------------------------------------------
# 5. Machine PATH content
# ---------------------------------------------------------------------------
$machinePath = ([Environment]::GetEnvironmentVariable('Path', 'Machine')) -split ';' |
    Where-Object { $_ } |
    ForEach-Object { $_.TrimEnd('\') }

$expectedPaths = @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Microsoft VS Code\bin',
    'C:\Program Files\PowerShell\7',
    'C:\Program Files\nodejs',
    'C:\ProgramData\nvm',
    'C:\ProgramData\npm',
    'C:\Program Files\Python312',
    'C:\Program Files\Python312\Scripts',
    'C:\Program Files\GitHub CLI',
    'C:\Program Files\Amazon\AWSCLIV2',
    'C:\Program Files\Terraform'
)
foreach ($p in $expectedPaths) {
    if ($machinePath -contains $p.TrimEnd('\')) {
        Add-CheckResult -Category 'Machine PATH' -Name $p -Status 'OK' -Detail 'Present'
    } else {
        Add-CheckResult -Category 'Machine PATH' -Name $p -Status 'WARN' -Detail 'Missing'
    }
}

# ---------------------------------------------------------------------------
# 6. Install manifest
# ---------------------------------------------------------------------------
$SetupDir     = 'C:\ProgramData\MasterElectronics\DevSetup'
$ManifestPath = Join-Path $SetupDir 'manifest.json'

if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $pkgCount = if ($manifest.PSObject.Properties.Name -contains 'Packages') {
            ($manifest.Packages | Measure-Object).Count
        } else { 0 }
        $errCount = if ($manifest.PSObject.Properties.Name -contains 'Errors') {
            ($manifest.Errors | Measure-Object).Count
        } else { 0 }
        $warnCount = if ($manifest.PSObject.Properties.Name -contains 'Warnings') {
            ($manifest.Warnings | Measure-Object).Count
        } else { 0 }

        $detail = "Schema=$($manifest.SchemaVersion) Started=$($manifest.StartTime) " +
                  "Packages=$pkgCount Errors=$errCount Warnings=$warnCount"
        $status = if ($errCount -gt 0) { 'WARN' } else { 'OK' }
        Add-CheckResult -Category 'Install State' -Name 'manifest.json' -Status $status -Detail $detail

        if ($errCount -gt 0) {
            foreach ($e in $manifest.Errors) {
                Add-CheckResult -Category 'Install State' -Name 'Manifest Error' `
                    -Status 'FAIL' -Detail $e
            }
        }
    } catch {
        Add-CheckResult -Category 'Install State' -Name 'manifest.json' -Status 'WARN' `
            -Detail "Exists but unparseable: $($_.Exception.Message)"
    }
} else {
    Add-CheckResult -Category 'Install State' -Name 'manifest.json' -Status 'FAIL' `
        -Detail "Not found at $ManifestPath"
}

# ---------------------------------------------------------------------------
# 7. Setup directory contents
# ---------------------------------------------------------------------------
$expectedFiles = @(
    'Configure-UserEnvironment.ps1',
    'Install-DevEnvironment.ps1',
    'vscode-extensions.json'
)
foreach ($f in $expectedFiles) {
    $full = Join-Path $SetupDir $f
    if (Test-Path -LiteralPath $full) {
        Add-CheckResult -Category 'Install State' -Name "DevSetup\$f" -Status 'OK' -Detail 'Present'
    } else {
        Add-CheckResult -Category 'Install State' -Name "DevSetup\$f" -Status 'WARN' `
            -Detail "Missing from $SetupDir"
    }
}

# ---------------------------------------------------------------------------
# 8. Per-user configuration state
# ---------------------------------------------------------------------------
$skipProfiles = @('Default','Default User','Public','All Users','WDAGUtilityAccount')
$userProfiles = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        ($skipProfiles -notcontains $_.Name) -and
        (Test-Path (Join-Path $_.FullName 'NTUSER.DAT'))
    }

if (-not $userProfiles) {
    Add-CheckResult -Category 'User Profiles' -Name '(none found)' -Status 'INFO' `
        -Detail 'No real user profiles on this machine yet'
}

foreach ($p in $userProfiles) {
    $coreMarker = Join-Path $p.FullName '.claude\.devsetup-core-configured'
    $extMarker  = Join-Path $p.FullName '.claude\.devsetup-vscode-extensions-configured'
    $extDir     = Join-Path $p.FullName '.vscode\extensions'

    $coreOK = Test-Path -LiteralPath $coreMarker
    $extOK  = Test-Path -LiteralPath $extMarker

    $extCount = 0
    if (Test-Path -LiteralPath $extDir) {
        $extCount = (Get-ChildItem $extDir -Directory -ErrorAction SilentlyContinue |
            Measure-Object).Count
    }

    $detail = "core=$coreOK ext-marker=$extOK extensions-on-disk=$extCount"
    $status = if ($coreOK -and $extOK -and $extCount -ge 10) {
        'OK'
    } elseif ($coreOK -and ($extOK -or $extCount -ge 10)) {
        'WARN'
    } else {
        'FAIL'
    }
    Add-CheckResult -Category 'User Profiles' -Name $p.Name -Status $status -Detail $detail
}

# ---------------------------------------------------------------------------
# 9. Logon scheduled task
# ---------------------------------------------------------------------------
$task = Get-ScheduledTask -TaskName 'MasterElectronics-ConfigureUserEnvironment' `
    -ErrorAction SilentlyContinue
if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    $code = $info.LastTaskResult
    $detail = "State=$($task.State) LastRun=$($info.LastRunTime) LastResult=$code"

    if ($code -eq 0) {
        $status = 'OK'
    } elseif ($code -eq 267011) {
        $status = 'INFO'
        $detail += ' (task has never run)'
    } else {
        switch ($code) {
            3221225786 { $detail += ' (STATUS_CONTROL_C_EXIT - process terminated mid-run)' }
            267009     { $detail += ' (SCHED_S_TASK_RUNNING - currently running)' }
            267014     { $detail += ' (SCHED_S_TASK_TERMINATED)' }
        }
        $status = 'WARN'
    }
    Add-CheckResult -Category 'Scheduled Task' `
        -Name 'MasterElectronics-ConfigureUserEnvironment' `
        -Status $status -Detail $detail
} else {
    Add-CheckResult -Category 'Scheduled Task' `
        -Name 'MasterElectronics-ConfigureUserEnvironment' `
        -Status 'FAIL' -Detail 'Task not registered'
}

# ---------------------------------------------------------------------------
# 10. Render results
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'RESULTS BY CATEGORY'
Write-Host '----------------------------------------------------------------'

$Results | Group-Object Category | ForEach-Object {
    Write-Host ''
    Write-Host "[$($_.Name)]"
    foreach ($r in $_.Group) {
        $tag  = "[$($r.Status)]".PadRight(7)
        $name = $r.Name.PadRight(42)
        Write-Host "  $tag $name $($r.Detail)"
    }
}

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
$total  = $Results.Count
$ok     = ($Results | Where-Object Status -eq 'OK').Count
$warn   = ($Results | Where-Object Status -eq 'WARN').Count
$fail   = ($Results | Where-Object Status -eq 'FAIL').Count
$info   = ($Results | Where-Object Status -eq 'INFO').Count
$elapsed = ((Get-Date) - $startTime).TotalSeconds

Write-Host ''
Write-Host '================================================================'
Write-Host ('  SUMMARY: {0} OK | {1} WARN | {2} FAIL | {3} INFO  (total {4})' -f $ok, $warn, $fail, $info, $total)
Write-Host ('  Elapsed: {0:N1}s' -f $elapsed)
Write-Host '================================================================'

if ($fail -gt 0) {
    Write-Host ''
    Write-Host 'FAILURES:'
    $Results | Where-Object Status -eq 'FAIL' | ForEach-Object {
        Write-Host "  - [$($_.Category)] $($_.Name): $($_.Detail)"
    }
    exit 1
}

exit 0
