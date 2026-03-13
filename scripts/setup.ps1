# =============================================================================
# Initial Setup - Run before first 'docker compose up'
# =============================================================================
# Creates .env if it doesn't exist and reminds you to generate auth.
# =============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

# Create .env from example if missing
if (-not (Test-Path ".env")) {
    Write-Host "Creating .env from .env.example..."
    Copy-Item ".env.example" ".env"
    Write-Host "  -> Edit .env and set your passwords/domain before starting!"
} else {
    Write-Host ".env already exists"
}

$AuthDir = Join-Path $RootDir "traefik\auth"
New-Item -ItemType Directory -Path $AuthDir -Force | Out-Null
$RedisDir = Join-Path $RootDir "redis"
New-Item -ItemType Directory -Path $RedisDir -Force | Out-Null
$RedisAclFile = Join-Path $RedisDir ".users.acl"
$RedisAclExample = Join-Path $RedisDir ".users.acl.example"
if (Test-Path $RedisAclFile) {
    Write-Host "redis/.users.acl already exists"
} else {
    Write-Host "Creating redis/.users.acl from redis/.users.acl.example..."
    Copy-Item $RedisAclExample $RedisAclFile
    Write-Host "  -> Edit redis/.users.acl before using per-app Redis ACL users"
}
if (Test-Path (Join-Path $AuthDir ".htpasswd")) {
    Write-Host ".htpasswd already exists"
} else {
    Write-Host ".htpasswd not found"
    Write-Host "  -> Production: run .\scripts\generate-auth.ps1 and choose a strong password"
    Write-Host "  -> Local dev quick auth: .\scripts\generate-auth.ps1 -Username admin -Password admin"
}

Write-Host ""
Write-Host "Setup complete! Next steps:"
Write-Host "  1. Edit .env with your domain, passwords, and ACME email"
Write-Host "  2. Generate Traefik BasicAuth before production start: .\scripts\generate-auth.ps1"
Write-Host "  3. For local dev, you can use quick auth: .\scripts\generate-auth.ps1 -Username admin -Password admin"
Write-Host "  4. Run: docker compose up -d"
Write-Host "  5. Ensure DNS: example.com, api.example.com, pgadmin.db.example.com, etc. -> server IP"
Write-Host ""
