# Add local domain entries to hosts file for LOCAL testing only (requires Administrator)
# Do not run this on production servers.
# Run: Right-click PowerShell -> Run as Administrator, then:
#   cd C:\path\to\server-infra
#   .\scripts\add-hosts.ps1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$EnvPath = Join-Path $RootDir ".env"
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

function Get-DomainFromEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*DOMAIN\s*=\s*(.+?)\s*$') {
            $value = $matches[1].Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return $null
}

$domain = Get-DomainFromEnv -Path $EnvPath
if ([string]::IsNullOrWhiteSpace($domain)) {
    throw "DOMAIN is missing in .env. Set DOMAIN (for example DOMAIN=local.com) and run again."
}

$hostnames = @(
    "pgadmin.db.$domain",
    "redis.db.$domain",
    "docker.$domain",
    "uptime.$domain",
    "traefik.$domain"
)

$content = Get-Content $hostsPath -Raw
$missingHostnames = @()
foreach ($hostname in $hostnames) {
    if ($content -notmatch "(?m)(^|\s)$([regex]::Escape($hostname))(\s|$)") {
        $missingHostnames += $hostname
    }
}

if ($missingHostnames.Count -eq 0) {
    Write-Host "Server Infra hosts entries for '$domain' already exist. Skipping."
    exit 0
}

$entries = @("")
$entries += "# Server Infra - local testing (admin tools only)"
foreach ($hostname in $missingHostnames) {
    $entries += "127.0.0.1 $hostname"
}

Add-Content -Path $hostsPath -Value ($entries -join [Environment]::NewLine)
Write-Host "Added infra hosts entries for '$domain'. Add app domains as needed."
