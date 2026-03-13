#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
REDIS_DIR="$ROOT_DIR/redis"
ACL_FILE="$REDIS_DIR/.users.acl"
ACL_EXAMPLE="$REDIS_DIR/.users.acl.example"

USERNAME="${1:-}"
PASSWORD="${2:-}"
PREFIX="${3:-}"

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
  echo "Usage: ./scripts/manage-redis-acl.sh <username> <password> [prefix]" >&2
  exit 1
fi

if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Username may contain only letters, numbers, underscore, and hyphen." >&2
  exit 1
fi

if [ "$USERNAME" = "default" ]; then
  echo "The default Redis user is managed separately. Use a named app user instead." >&2
  exit 1
fi

if [ -z "$PREFIX" ]; then
  PREFIX="$USERNAME"
fi

mkdir -p "$REDIS_DIR"

if [ ! -f "$ACL_FILE" ]; then
  if [ -f "$ACL_EXAMPLE" ]; then
    cp "$ACL_EXAMPLE" "$ACL_FILE"
  else
    : > "$ACL_FILE"
  fi
fi

NEW_LINE="user $USERNAME on >$PASSWORD ~$PREFIX:* &* +@all -@dangerous +info"
TMP_FILE="$(mktemp)"

awk -v username="$USERNAME" '
  /^[[:space:]]*#/ { next }
  $1 == "user" && $2 == username { next }
  { print }
' "$ACL_FILE" > "$TMP_FILE"

printf "%s\n" "$NEW_LINE" >> "$TMP_FILE"
mv "$TMP_FILE" "$ACL_FILE"

echo "Updated redis ACL user: $USERNAME"
echo "Prefix: $PREFIX:*"
echo "Restart Redis to apply: docker compose up -d redis"
