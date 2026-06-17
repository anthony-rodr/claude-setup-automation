$ErrorActionPreference = 'Stop'

$NativeBinary = 'C:\ProgramData\Claude\bin\claude.exe'
$NativeBinDir = 'C:\ProgramData\Claude\bin'

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message"
}

Write-Host ''
Write-Host '========================================='
Write-Host '  Master Electronics — Claude Code Repair'
Write-Host '========================================='
Write-Host "  Computer : $env:COMPUTERNAME"
Write-Host "  Run as   : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host '========================================='
Write-Host ''

$anyFixed = $false

# ── 1. Remove npm-installed Claude Code shims from all known prefix locations ──
Write-Status 'Scanning for npm-installed Claude Code shims...'

$prefixes = @('C:\ProgramData\npm', 'C:\Program Files\nodejs')

# Per-user npm roaming dirs
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('Default', 'Default User', 'Public', 'All Users', 'WDAGUtilityAccount') } |
    ForEach-Object { $prefixes += Join-Path $_.FullName 'AppData\Roaming\npm' }

foreach ($prefix in ($prefixes | Select-Object -Unique)) {
    if (-not (Test-Path $prefix)) { continue }

    $shims = @('claude.ps1','claude.cmd','claude') |
             ForEach-Object { Join-Path $prefix $_ } |
             Where-Object { Test-Path $_ }

    if (-not $shims) { continue }

    Write-Status "Found shims in: $prefix" 'WARN'

    # Attempt npm uninstall first (cleans node_modules too)
    try {
        $npm = (Get-Command npm -ErrorAction Stop).Source
        $out = & $npm uninstall -g @anthropic-ai/claude-code 2>&1
        Write-Status "  npm uninstall: $($out | Select-Object -Last 1)" 'DIAG'
    } catch {}

    # Remove any shim files still present
    foreach ($shim in $shims) {
        if (Test-Path $shim) {
            Remove-Item $shim -Force -ErrorAction SilentlyContinue
            Write-Status "  Removed: $shim" 'OK'
            $anyFixed = $true
        }
    }
}

if (-not $anyFixed) {
    Write-Status 'No npm shims found.' 'OK'
}

# ── 2. Verify native binary exists ─────────────────────────────────────────────
Write-Host ''
Write-Status 'Checking native binary...'

if (-not (Test-Path $NativeBinary)) {
    Write-Status "Native binary NOT found at $NativeBinary" 'FAIL'
    Write-Status 'Run AIE-Claude-Deployment to reinstall.' 'WARN'
    exit 1
}

$ver = try { & $NativeBinary --version 2>&1 | Select-Object -First 1 } catch { 'unknown' }
Write-Status "Native binary present: $ver" 'OK'

# ── 3. Ensure native bin dir is in machine PATH ────────────────────────────────
Write-Host ''
Write-Status 'Checking machine PATH...'

$machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($machinePath -notlike "*$NativeBinDir*") {
    [System.Environment]::SetEnvironmentVariable('PATH', "$machinePath;$NativeBinDir", 'Machine')
    Write-Status "Added $NativeBinDir to machine PATH." 'OK'
    $anyFixed = $true
} else {
    Write-Status "Machine PATH already contains $NativeBinDir." 'OK'
}

# ── 4. Final resolution check ──────────────────────────────────────────────────
Write-Host ''
Write-Host '========================================='
$resolved = Get-Command claude -ErrorAction SilentlyContinue
if ($resolved) {
    if ($resolved.Source -like '*ProgramData\Claude*') {
        Write-Status "claude -> $($resolved.Source)" 'OK'
        Write-Status 'Claude Code is correctly pointing to the native binary.' 'OK'
    } else {
        Write-Status "claude -> $($resolved.Source)" 'WARN'
        Write-Status 'Unexpected source — may need investigation.' 'WARN'
    }
} else {
    Write-Status 'claude not found on current PATH (PATH changes need a new terminal).' 'WARN'
    Write-Status "Native binary is at: $NativeBinary" 'OK'
}

if ($anyFixed) {
    Write-Status 'Fixes applied. User needs to open a new terminal for changes to take effect.' 'OK'
} else {
    Write-Status 'No changes needed.' 'OK'
}
Write-Host '========================================='
