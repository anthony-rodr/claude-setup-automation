#Requires -Version 7
<#
.SYNOPSIS
    PSU Job: Build package, upload to S3, generate pre-signed URLs.

.DESCRIPTION
    Runs on a schedule or manual trigger from PowerShell Universal.
    Connects via WinRM to the Windows dev machine, builds the release package,
    uploads to private S3, then outputs fresh pre-signed URLs to copy into
    NinjaOne Script Variables manually.

.PSU SECRETS REQUIRED
    WinRMCredential       — PSCredential for Windows dev machine admin account
    AWS_ACCESS_KEY_ID     — IAM key with s3:PutObject + s3:GetObject on the bucket
    AWS_SECRET_ACCESS_KEY — Secret for above

.NOTES
    One-time setup on Windows dev machine (run elevated):
        Enable-PSRemoting -Force
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'host.docker.internal' -Force

    After this job completes, copy the three URLs printed at the end into
    NinjaOne Bootstrap automation Script Variables:
        deployurl
        versionsurl
        packageurl
#>

$ErrorActionPreference = 'Stop'

# ── Config ─────────────────────────────────────────────────────────────────────
$S3Bucket      = 'claude-deploy-scripts'
$S3Prefix      = 'Windows'
$S3Region      = 'us-east-2'
$ProjectRoot   = 'C:\projects\claude-setup-automation'
$UrlExpiryDays = 7
$UrlExpirySecs = $UrlExpiryDays * 86400

# ── Secrets from PSU vault ─────────────────────────────────────────────────────
$winCred      = Get-PSUVariable -Name 'WinRMCredential'
$awsKeyId     = Get-PSUVariable -Name 'AWS_ACCESS_KEY_ID'
$awsKeySecret = Get-PSUVariable -Name 'AWS_SECRET_ACCESS_KEY'

# ── Step 1 & 2 & 3: Build, upload, presign on Windows dev machine ──────────────
$urls = Invoke-Command -ComputerName 'host.docker.internal' `
    -Credential $winCred `
    -ArgumentList $ProjectRoot, $awsKeyId, $awsKeySecret, $S3Bucket, $S3Prefix, $S3Region, $UrlExpirySecs `
    -ScriptBlock {
        param($root, $keyId, $keySecret, $bucket, $prefix, $region, $expiry)
        $ErrorActionPreference = 'Stop'

        # Step 1: Build
        Write-Host "=== STEP 1: Building package ==="
        & "$root\scripts\Package-Release.ps1"
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Package-Release.ps1 failed (exit $LASTEXITCODE)" }

        # Set AWS credentials for this session only — never written to disk
        $env:AWS_ACCESS_KEY_ID     = $keyId
        $env:AWS_SECRET_ACCESS_KEY = $keySecret
        $env:AWS_DEFAULT_REGION    = $region

        # Step 2: Upload
        Write-Host "`n=== STEP 2: Uploading to S3 ==="
        $uploads = @{
            "$prefix/Deploy-DevEnvironment.ps1"   = "$root\scripts\Deploy-DevEnvironment.ps1"
            "$prefix/VERSIONS.md"                 = "$root\VERSIONS.md"
            "$prefix/claude-setup-automation.zip" = "$root\claude-setup-automation.zip"
        }
        foreach ($key in $uploads.Keys) {
            aws s3 cp $uploads[$key] "s3://$bucket/$key" --no-progress
            if ($LASTEXITCODE -ne 0) { throw "Upload failed: $($uploads[$key])" }
            Write-Host "  OK: $key"
        }

        # Step 3: Generate pre-signed URLs
        Write-Host "`n=== STEP 3: Generating pre-signed URLs ($([int]($expiry/86400))-day expiry) ==="
        $urls = @{
            deployurl   = (aws s3 presign "s3://$bucket/$prefix/Deploy-DevEnvironment.ps1"   --expires-in $expiry).Trim()
            versionsurl = (aws s3 presign "s3://$bucket/$prefix/VERSIONS.md"                 --expires-in $expiry).Trim()
            packageurl  = (aws s3 presign "s3://$bucket/$prefix/claude-setup-automation.zip" --expires-in $expiry).Trim()
        }

        if (-not $urls.deployurl -or -not $urls.versionsurl -or -not $urls.packageurl) {
            throw 'One or more pre-signed URLs were empty. Check AWS credentials and bucket name.'
        }

        return $urls
    }

# ── Output URLs to copy into NinjaOne ─────────────────────────────────────────
$expiry = (Get-Date).AddDays($UrlExpiryDays).ToString('yyyy-MM-dd')

Write-Host ''
Write-Host '=========================================='
Write-Host ' COPY THESE INTO NINJAONE SCRIPT VARIABLES'
Write-Host '=========================================='
Write-Host ''
Write-Host "deployurl"
Write-Host $urls.deployurl
Write-Host ''
Write-Host "versionsurl"
Write-Host $urls.versionsurl
Write-Host ''
Write-Host "packageurl"
Write-Host $urls.packageurl
Write-Host ''
Write-Host "=========================================="
Write-Host "URLs expire: $expiry — run this job again before that date."
Write-Host '=========================================='
