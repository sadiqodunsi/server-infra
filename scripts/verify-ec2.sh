#!/usr/bin/env bash
# =============================================================================
# EC2 Verification - Preflight + Post-Deploy Checks
# =============================================================================
# Validates host prerequisites, required project files, compose config, container
# status, and key service health checks for this server-infra stack.
#
# Usage:
#   ./scripts/verify-ec2.sh
#
# Optional:
#   VERIFY_DOMAIN=example.com ./scripts/verify-ec2.sh
#   CHECK_HTTP=1 ./scripts/verify-ec2.sh
#   VERIFY_DOMAIN=example.com CHECK_HTTP=1 ./scripts/verify-ec2.sh
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR" || exit 1

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "%b[PASS]%b %s\n" "$GREEN" "$RESET" "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$1"
}

section() {
  printf "\n%b== %s ==%b\n" "$BOLD$BLUE" "$1" "$RESET"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_env_value() {
  # Reads KEY=value from .env with simple parsing.
  # Ignores commented lines and trims surrounding quotes.
  local key="$1"
  [ -f ".env" ] || return 1

  local raw
  raw="$(awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' .env 2>/dev/null || true)"
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf "%s" "$raw"
}

check_file_permissions() {
  local file="$1"
  local expected="$2"
  [ -f "$file" ] || {
    fail "Missing required file: $file"
    return
  }

  if command_exists stat; then
    local mode
    mode="$(stat -c "%a" "$file" 2>/dev/null || true)"
    if [ -n "$mode" ] && [ "$mode" != "$expected" ]; then
      warn "$file permissions are $mode (recommended $expected)"
    else
      pass "$file exists (permissions check OK)"
    fi
  else
    pass "$file exists"
  fi
}

check_required_env() {
  local key="$1"
  local value
  value="$(get_env_value "$key" || true)"

  if [ -z "$value" ]; then
    fail ".env missing value for: $key"
    return
  fi

  if [[ "$value" == CHANGE_ME* ]]; then
    warn ".env value for $key still looks default (starts with CHANGE_ME)"
    return
  fi

  pass ".env value present: $key"
}

section "Host prerequisites"

if command_exists docker; then
  pass "docker command is available"
else
  fail "docker is not installed or not in PATH"
fi

if docker compose version >/dev/null 2>&1; then
  pass "docker compose plugin is available"
else
  fail "docker compose plugin is not available"
fi

if docker info >/dev/null 2>&1; then
  pass "docker daemon is reachable"
else
  fail "docker daemon is not reachable (check service/user permissions)"
fi

section "Project files and secrets"

[ -f "docker-compose.yml" ] && pass "docker-compose.yml exists" || fail "docker-compose.yml missing"
[ -f ".env" ] && pass ".env exists" || fail ".env missing (run ./scripts/setup.sh first)"
[ -f "redis/.users.acl" ] && pass "redis/.users.acl exists" || fail "redis/.users.acl missing"
[ -f "traefik/auth/.htpasswd" ] && pass "traefik/auth/.htpasswd exists" || fail "traefik/auth/.htpasswd missing"

check_file_permissions ".env" "600"
check_file_permissions "redis/.users.acl" "600"
check_file_permissions "traefik/auth/.htpasswd" "600"

section ".env sanity checks"

check_required_env "DOMAIN"
check_required_env "ACME_EMAIL"
check_required_env "ADMIN_IP_ALLOWLIST"
check_required_env "POSTGRES_USER"
check_required_env "POSTGRES_PASSWORD"
check_required_env "POSTGRES_DB"
check_required_env "PGADMIN_EMAIL"
check_required_env "PGADMIN_PASSWORD"
check_required_env "REDIS_MAXMEMORY"
check_required_env "REDIS_MAXMEMORY_POLICY"

DOMAIN_FROM_ENV="$(get_env_value "DOMAIN" || true)"
PG_USER_FROM_ENV="$(get_env_value "POSTGRES_USER" || true)"
PG_DB_FROM_ENV="$(get_env_value "POSTGRES_DB" || true)"
VERIFY_DOMAIN="${VERIFY_DOMAIN:-$DOMAIN_FROM_ENV}"
if [ -n "${VERIFY_DOMAIN:-}" ]; then
  pass "Using domain for endpoint checks: $VERIFY_DOMAIN"
else
  warn "No domain available for endpoint checks (set .env DOMAIN or VERIFY_DOMAIN)"
fi

section "Compose validation"

if docker compose config >/dev/null 2>&1; then
  pass "docker compose config is valid"
else
  fail "docker compose config failed (inspect output with: docker compose config)"
fi

section "Redis ACL mount readability"

if [ -n "$(docker compose ps -q redis 2>/dev/null || true)" ]; then
  if docker compose exec -T redis sh -lc 'test -r /usr/local/etc/redis/.users.acl' >/dev/null 2>&1; then
    pass "Redis container can read mounted ACL file"
  else
    fail "Redis container cannot read mounted ACL file (/usr/local/etc/redis/.users.acl)"
  fi
else
  if docker compose run --rm --no-deps --entrypoint sh redis -lc 'test -r /usr/local/etc/redis/.users.acl' >/dev/null 2>&1; then
    pass "Redis service can read mounted ACL file (startup precheck)"
  else
    fail "Redis service cannot read mounted ACL file; fix host file perms/ACLs for redis/.users.acl"
  fi
fi

section "Container status"

if docker compose ps >/dev/null 2>&1; then
  pass "docker compose project detected"
else
  warn "docker compose project not running yet (this is okay pre-deploy)"
fi

SERVICES="traefik redis postgres pgadmin redisinsight uptime-kuma"
for svc in $SERVICES; do
  cid="$(docker compose ps -q "$svc" 2>/dev/null || true)"
  if [ -z "$cid" ]; then
    warn "Service not created/running: $svc"
    continue
  fi

  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"

  if [ "$running" = "true" ]; then
    if [ "$health" = "healthy" ] || [ "$health" = "none" ]; then
      pass "$svc is running (health=$health)"
    else
      warn "$svc is running but health=$health"
    fi
  else
    fail "$svc container exists but is not running"
  fi
done

section "In-container service checks"

if docker compose ps -q postgres >/dev/null 2>&1 && [ -n "$(docker compose ps -q postgres 2>/dev/null)" ]; then
  if [ -z "$PG_USER_FROM_ENV" ] || [ -z "$PG_DB_FROM_ENV" ]; then
    warn "Skipping Postgres query check (.env POSTGRES_USER/POSTGRES_DB missing)"
  elif docker compose exec -T postgres psql -U "$PG_USER_FROM_ENV" -d "$PG_DB_FROM_ENV" -c "SELECT 1;" >/dev/null 2>&1; then
    pass "Postgres responds to SELECT 1"
  else
    warn "Postgres query check failed (.env user/db: $PG_USER_FROM_ENV / $PG_DB_FROM_ENV)"
  fi
else
  warn "Skipping Postgres query check (container not running)"
fi

if docker compose ps -q redis >/dev/null 2>&1 && [ -n "$(docker compose ps -q redis 2>/dev/null)" ]; then
  if docker compose exec -T redis redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null | grep -Eq "PONG|NOAUTH"; then
    pass "Redis responds to ping"
  else
    warn "Redis ping check failed"
  fi
else
  warn "Skipping Redis ping check (container not running)"
fi

section "Endpoint checks (optional)"

if [ -n "${VERIFY_DOMAIN:-}" ]; then
  if command_exists getent; then
    if getent hosts "traefik.${VERIFY_DOMAIN}" >/dev/null 2>&1; then
      pass "DNS resolves: traefik.${VERIFY_DOMAIN}"
    else
      warn "DNS does not resolve yet: traefik.${VERIFY_DOMAIN}"
    fi
  else
    warn "getent not found; skipping DNS resolution checks"
  fi

  if [ "${CHECK_HTTP:-0}" = "1" ]; then
    if command_exists curl; then
      for host in "traefik.${VERIFY_DOMAIN}" "pgadmin.db.${VERIFY_DOMAIN}" "redis.db.${VERIFY_DOMAIN}" "uptime.${VERIFY_DOMAIN}"; do
        code="$(curl -k -s -o /dev/null -m 8 -w "%{http_code}" "https://${host}" || true)"
        if [ "$code" = "401" ] || [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "404" ]; then
          pass "HTTPS reachable: ${host} (HTTP ${code})"
        else
          warn "HTTPS check failed: ${host} (HTTP ${code:-n/a})"
        fi
      done
    else
      warn "curl not found; skipping HTTPS endpoint checks"
    fi
  else
    warn "Skipping HTTPS checks (set CHECK_HTTP=1 to enable)"
  fi
else
  warn "Skipping endpoint checks (no domain available)"
fi

section "Result"
printf "%bPass:%b %s | %bWarn:%b %s | %bFail:%b %s\n" \
  "$GREEN" "$RESET" "$PASS_COUNT" \
  "$YELLOW" "$RESET" "$WARN_COUNT" \
  "$RED" "$RESET" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf "%bVerification completed with failures.%b\n" "$RED" "$RESET"
  exit 1
fi

printf "%bVerification completed (no hard failures).%b\n" "$GREEN" "$RESET"
exit 0
