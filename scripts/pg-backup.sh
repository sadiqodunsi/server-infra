#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
RUN_DIR="$BACKUP_DIR/$TIMESTAMP"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-postgres}"
AWS_REGION="${AWS_REGION:-}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"

mkdir -p "$RUN_DIR"

echo "Creating Postgres backup set: $RUN_DIR"

docker_exec() {
  docker compose \
    -f "$ROOT_DIR/docker-compose.yml" \
    --project-directory "$ROOT_DIR" \
    exec -T postgres sh -lc "$1"
}

docker_exec 'pg_dumpall -U "$POSTGRES_USER" --globals-only' | gzip > "$RUN_DIR/globals.sql.gz"

mapfile -t DATABASES < <(
  docker_exec 'psql -U "$POSTGRES_USER" -At -c "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"'
)

for DB_NAME in "${DATABASES[@]}"; do
  echo "Backing up database: $DB_NAME"
  docker_exec "pg_dump -U \"\$POSTGRES_USER\" \"$DB_NAME\"" | gzip > "$RUN_DIR/$DB_NAME.sql.gz"
done

if [ -n "$S3_BUCKET" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "aws CLI is required for S3 upload but was not found" >&2
    exit 1
  fi

  S3_KEY_PREFIX="${S3_PREFIX%/}/$TIMESTAMP/"
  AWS_ARGS=()

  if [ -n "$AWS_REGION" ]; then
    AWS_ARGS+=(--region "$AWS_REGION")
  fi

  if [ -n "$S3_ENDPOINT_URL" ]; then
    AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")
  fi

  echo "Uploading backup set to s3://$S3_BUCKET/$S3_KEY_PREFIX"
  aws s3 cp "$RUN_DIR" "s3://$S3_BUCKET/$S3_KEY_PREFIX" --recursive "${AWS_ARGS[@]}"
fi

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

echo "Backup complete"
