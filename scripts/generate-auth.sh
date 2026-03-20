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

# Mirror generate-auth.ps1 pattern: get password in script, then run non-interactive htpasswd.
if [ -z "$PASSWORD" ]; then
    read -r -s -p "Enter password for $USERNAME: " PASSWORD
    echo
    read -r -s -p "Confirm password for $USERNAME: " PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "Passwords do not match." >&2
        exit 1
    fi
    if [ -z "$PASSWORD" ]; then
        echo "Password cannot be empty." >&2
        exit 1
    fi
fi

echo "Generating .htpasswd using Docker..."
docker run --rm httpd:alpine htpasswd -nbB "$USERNAME" "$PASSWORD" > "$TMP_OUTPUT"

# Guardrail: refuse to write invalid output (e.g., usage text) into .htpasswd.
# We normalize CRLF and extract only a valid bcrypt entry line for this user.
VALID_ENTRY="$(
    tr -d '\r' < "$TMP_OUTPUT" \
      | awk -F: -v u="$USERNAME" '$1 == u && $2 ~ /^\$2[aby]\$/ { print $0; exit }'
)"

if [ -z "$VALID_ENTRY" ]; then
    echo "Failed to generate a valid bcrypt htpasswd entry for user '$USERNAME'." >&2
    echo "Aborting without writing $AUTH_DIR/.htpasswd" >&2
    exit 1
fi

printf "%s\n" "$VALID_ENTRY" > "$AUTH_DIR/.htpasswd"
chmod 600 "$AUTH_DIR/.htpasswd"
echo "Created $AUTH_DIR/.htpasswd - ensure this file is in .gitignore!"
