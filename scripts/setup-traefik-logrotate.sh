#!/usr/bin/env bash
# =============================================================================
# Setup logrotate for Traefik access.log (Docker volume-backed file)
# =============================================================================
# Installs /etc/logrotate.d/server-infra-traefik-access for:
#   <traefik-logs volume mountpoint>/access.log
#
# Usage:
#   ./scripts/setup-traefik-logrotate.sh
# =============================================================================

set -euo pipefail

LOGROTATE_FILE="/etc/logrotate.d/server-infra-traefik-access"
VOLUME_NAME="traefik-logs"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required but not found." >&2
  exit 1
fi

if ! command -v logrotate >/dev/null 2>&1; then
  echo "logrotate is required but not found. Install it first (e.g. sudo apt-get install -y logrotate)." >&2
  exit 1
fi

MOUNTPOINT="$(docker volume inspect "$VOLUME_NAME" -f '{{.Mountpoint}}' 2>/dev/null || true)"
if [ -z "$MOUNTPOINT" ]; then
  echo "Docker volume '$VOLUME_NAME' not found." >&2
  echo "Start the stack once (docker compose up -d) so the volume exists, then run again." >&2
  exit 1
fi

ACCESS_LOG_PATH="$MOUNTPOINT/access.log"
if [ ! -f "$ACCESS_LOG_PATH" ]; then
  # Ensure file exists so logrotate has a stable target.
  touch "$ACCESS_LOG_PATH"
fi

sudo tee "$LOGROTATE_FILE" >/dev/null <<EOF
$ACCESS_LOG_PATH {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root root
}
EOF

echo "Installed logrotate config: $LOGROTATE_FILE"
echo "Target log file: $ACCESS_LOG_PATH"
echo ""
echo "Validation commands:"
echo "  sudo logrotate -d $LOGROTATE_FILE"
echo "  sudo logrotate -f $LOGROTATE_FILE"
