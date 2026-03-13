param(
    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$Prefix
)

if ($Username -notmatch '^[A-Za-z0-9_-]+$') {
    throw "Username may contain only letters, numbers, underscore, and hyphen."
}

if ($Username -eq "default") {
    throw "The default Redis user is managed separately. Use a named app user instead."
}

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix = $Username
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$RedisDir = Join-Path $RootDir "redis"
$AclFile = Join-Path $RedisDir ".users.acl"
$AclExample = Join-Path $RedisDir ".users.acl.example"

New-Item -ItemType Directory -Path $RedisDir -Force | Out-Null

if (-not (Test-Path $AclFile)) {
    if (Test-Path $AclExample) {
        Copy-Item $AclExample $AclFile
    } else {
        New-Item -ItemType File -Path $AclFile -Force | Out-Null
    }
}

$NewLine = "user $Username on >$Password ~${Prefix}:* &* +@all -@dangerous +info"
$Lines = Get-Content $AclFile -ErrorAction SilentlyContinue
$Filtered = @()

foreach ($Line in $Lines) {
    if ($Line -match '^\s*#') {
        continue
    }
    if ($Line -match "^user\s+$([regex]::Escape($Username))(\s|$)") {
        continue
    }
    $Filtered += $Line
}

$Filtered += $NewLine
[System.IO.File]::WriteAllLines($AclFile, $Filtered, [System.Text.UTF8Encoding]::new($false))

Write-Host "Updated redis ACL user: $Username"
Write-Host "Prefix: ${Prefix}:*"
Write-Host "Restart Redis to apply: docker compose up -d redis"
