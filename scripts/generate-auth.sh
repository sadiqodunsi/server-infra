#!/bin/bash
# =============================================================================
# Generate .htpasswd for Traefik BasicAuth
# =============================================================================
# Run this script to create traefik/auth/.htpasswd for protecting admin tools
# (pgAdmin, Portainer, Uptime Kuma). Uses bcrypt for secure password hashing.
#
# Usage:
#   ./scripts/generate-auth.sh [username] [password]
#
# If password is omitted, you will be prompted interactively.
# For local-only quick auth you can use:
#   ./scripts/generate-auth.sh admin admin
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_DIR="$(dirname "$SCRIPT_DIR")/traefik/auth"
USERNAME="${1:-admin}"
PASSWORD="${2:-}"

mkdir -p "$AUTH_DIR"
echo "Creating .htpasswd for user: $USERNAME"
TMP_OUTPUT="$(mktemp)"

cleanup() {
    rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT

# Use Docker to run htpasswd if not available locally
if command -v htpasswd &> /dev/null; then
    if [ -n "$PASSWORD" ]; then
        htpasswd -nbB "$USERNAME" "$PASSWORD" > "$TMP_OUTPUT"
    else
        echo "Enter password (will not echo):"
        htpasswd -nB "$USERNAME" > "$TMP_OUTPUT"
    fi
else
    if [ -n "$PASSWORD" ]; then
        docker run --rm httpd:alpine htpasswd -nbB "$USERNAME" "$PASSWORD" > "$TMP_OUTPUT"
    else
        echo "Enter password (will not echo):"
        docker run --rm -it httpd:alpine htpasswd -nB "$USERNAME" > "$TMP_OUTPUT"
    fi
fi

# Guardrail: refuse to write invalid output (e.g., usage text) into .htpasswd
if ! grep -Eq "^${USERNAME}:\$2[aby]\$" "$TMP_OUTPUT"; then
    echo "Failed to generate a valid bcrypt htpasswd entry for user '$USERNAME'." >&2
    echo "Aborting without writing $AUTH_DIR/.htpasswd" >&2
    exit 1
fi

cp "$TMP_OUTPUT" "$AUTH_DIR/.htpasswd"
chmod 600 "$AUTH_DIR/.htpasswd"
echo "Created $AUTH_DIR/.htpasswd - ensure this file is in .gitignore!"
