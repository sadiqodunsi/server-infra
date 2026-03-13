# =============================================================================
# Generate .htpasswd for Traefik BasicAuth (Windows PowerShell)
# =============================================================================
# Run this script to create traefik/auth/.htpasswd for protecting admin tools.
#
# Usage:
#   .\scripts\generate-auth.ps1 -Username admin
#   .\scripts\generate-auth.ps1 -Username admin -Password admin
#
# If -Password is omitted, you will be prompted interactively.
# Requires Docker to be running (uses httpd:alpine for htpasswd).
# =============================================================================

param(
    [string]$Username = "admin",
    [string]$Password
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AuthDir = Join-Path (Split-Path -Parent $ScriptDir) "traefik\auth"

if (-not (Test-Path $AuthDir)) {
    New-Item -ItemType Directory -Path $AuthDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    $SecurePassword = Read-Host "Enter password for $Username" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
} else {
    $PlainPassword = $Password
}

Write-Host "Generating .htpasswd using Docker..."
$Output = docker run --rm httpd:alpine htpasswd -nbB $Username $PlainPassword
# Use Unix line endings (LF only) - CRLF causes Traefik BasicAuth to fail
$Output = ($Output -replace "`r", "").Trim()
$HtpasswdPath = Join-Path $AuthDir ".htpasswd"
[System.IO.File]::WriteAllText($HtpasswdPath, $Output + "`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "Created $AuthDir\.htpasswd - ensure this file is in .gitignore!"
