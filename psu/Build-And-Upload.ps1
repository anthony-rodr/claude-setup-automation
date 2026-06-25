#Requires -Version 7
<#
.SYNOPSIS
    PSU Job: Build package and upload to S3.
    Runs directly inside the PSU container against the mounted /claude-setup-automation volume.

.PSU VARIABLES REQUIRED (Platform > Variables, type Secret)
    AWS_ACCESS_KEY_ID     — IAM key with s3:PutObject on claude-deploy-scripts bucket
    AWS_SECRET_ACCESS_KEY — Secret for above

.NOTES
    No WinRM needed — project is mounted as a Docker volume at /claude-setup-automation.
    Pre-signed URLs are generated on demand by the aie-presign-url-claude-autodeployment Lambda.
    No NinjaOne update required after running this job.
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = '/claude-setup-automation'
$S3Bucket    = 'claude-deploy-scripts'
$S3Prefix    = 'Windows'
$S3Region    = 'us-east-2'

Import-Module AWS.Tools.S3 -ErrorAction Stop

# Diagnostic — remove after confirming variable injection works
Write-Host "AWS_ACCESS_KEY_ID injected: $(-not [string]::IsNullOrEmpty($AWS_ACCESS_KEY_ID))"
Write-Host "Available variables: $(Get-Variable | Where-Object { $_.Name -like 'AWS*' } | Select-Object -ExpandProperty Name)"

# Set AWS credentials as environment variables so both Write-S3Object and child processes can find them.
$env:AWS_ACCESS_KEY_ID     = $AWS_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY = $AWS_SECRET_ACCESS_KEY
$env:AWS_DEFAULT_REGION    = $S3Region

# === STEP 1: Build ===
# Run in a fresh pwsh process — PSU's runspace doesn't load Compress-Archive and other default modules.
Write-Host "=== STEP 1: Building package ==="
pwsh -NonInteractive -File "$ProjectRoot/scripts/Package-Release.ps1"
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Package-Release.ps1 failed (exit $LASTEXITCODE)" }
# Note: aws CLI upload warnings inside Package-Release.ps1 are expected — upload handled below.

# === STEP 2: Upload to S3 ===
Write-Host ""
Write-Host "=== STEP 2: Uploading to S3 ==="
$uploads = [ordered]@{
    "$S3Prefix/Deploy-DevEnvironment.ps1"   = "$ProjectRoot/scripts/Deploy-DevEnvironment.ps1"
    "$S3Prefix/VERSIONS.md"                 = "$ProjectRoot/VERSIONS.md"
    "$S3Prefix/claude-setup-automation.zip" = "$ProjectRoot/claude-setup-automation.zip"
}
foreach ($key in $uploads.Keys) {
    Write-Host "  Uploading $key..."
    Write-S3Object -BucketName $S3Bucket -Key $key -File $uploads[$key] -Region $S3Region
    Write-Host "  OK: $key"
}

Write-Host ""
Write-Host "=========================================="
Write-Host " BUILD AND UPLOAD COMPLETE"
Write-Host " Lambda generates pre-signed URLs on demand."
Write-Host " No NinjaOne update required."
Write-Host "=========================================="
