#!/bin/bash
# =============================================================================
# Initial Setup - Run before first 'docker compose up'
# =============================================================================
# Creates .env if it doesn't exist and reminds you to generate auth.
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Create .env from example if missing
if [ ! -f .env ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
    echo "  -> Edit .env and set your passwords/domain before starting!"
else
    echo ".env already exists"
fi

AUTH_DIR="$ROOT_DIR/traefik/auth"
mkdir -p "$AUTH_DIR"
REDIS_DIR="$ROOT_DIR/redis"
REDIS_ACL_FILE="$REDIS_DIR/.users.acl"
REDIS_ACL_EXAMPLE="$REDIS_DIR/.users.acl.example"
mkdir -p "$REDIS_DIR"

if [ -f "$REDIS_ACL_FILE" ]; then
    echo "redis/.users.acl already exists"
else
    echo "Creating redis/.users.acl from redis/.users.acl.example..."
    cp "$REDIS_ACL_EXAMPLE" "$REDIS_ACL_FILE"
    echo "  -> Edit redis/.users.acl before using per-app Redis ACL users"
fi

if [ -f "$AUTH_DIR/.htpasswd" ]; then
    echo ".htpasswd already exists"
else
    echo ".htpasswd not found"
    echo "  -> Production: run ./scripts/generate-auth.sh and choose a strong password"
    echo "  -> Local dev quick auth: ./scripts/generate-auth.sh admin admin"
fi

echo ""
echo "Setup complete! Next steps:"
echo "  1. Edit .env with your domain, passwords, and ACME email"
echo "  2. Generate Traefik BasicAuth before production start: ./scripts/generate-auth.sh"
echo "  3. For local dev, you can use quick auth: ./scripts/generate-auth.sh admin admin"
echo "  4. Run: docker compose up -d"
echo "  5. Ensure DNS: example.com, api.example.com, pgadmin.db.example.com, etc. -> server IP"
echo ""
