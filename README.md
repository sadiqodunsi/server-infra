# Server Infra Runbook

Reusable Docker infrastructure for multiple apps on one EC2 instance.

Services in this stack:

- Traefik (reverse proxy + TLS)
- Redis (shared cache/queue backend with ACL users)
- Postgres (shared database server)
- pgAdmin, RedisInsight, Uptime Kuma (admin/ops tools)
- Portainer (maintenance-only via admin profile)

This document is the operational guide for setup, maintenance, backup, and troubleshooting.

---

## Production Preflight Checklist

Run through this checklist before first production deploy:

- [ ] `.env` uses strong unique values (no `CHANGE_ME_*`)
- [ ] `redis/.users.acl` uses strong unique passwords for all users
- [ ] `ADMIN_IP_ALLOWLIST` is restricted to trusted admin IP/CIDR only
- [ ] DNS A records for admin subdomains point to this EC2 instance
- [ ] EC2 security group allows only `22` (restricted), `80`, and `443`
- [ ] Secret files exist and are permissioned to owner-only (`chmod 600`)
- [ ] Host `logrotate` is installed and Traefik access-log rotation is configured (`./scripts/setup-traefik-logrotate.sh`)
- [ ] `PORTAINER_EXPOSE=false` unless in an active maintenance window
- [ ] **Recommended:** backup is configured (`S3_BUCKET`/`AWS_REGION` as needed + systemd timer enabled)
- [ ] Backup path tested (`./scripts/pg-backup.sh`) and restore command validated

---

## 1) Architecture and Security Model

### Networks

- `traefik-network`: ingress/reverse-proxy traffic
- `backend-network`: internal service traffic (apps -> Postgres/Redis)

### Exposure model

- Production compose:
  - `postgres` and `redis` are internal only (no host-port publish)
  - admin UIs are behind Traefik routes
- Local override (`docker-compose.local.yml`):
  - Postgres/Redis bind to `127.0.0.1` only
  - local HTTP routers are enabled for testing

### Authentication model

- Traefik BasicAuth for admin routes (`traefik/auth/.htpasswd`)
- IP allowlist middleware (`ADMIN_IP_ALLOWLIST`)
- Redis ACL (`redis/.users.acl`) with:
  - `default` disabled
  - one infra user (`redis_admin`)
  - one named user per app + key prefix scope

### Runtime hardening already configured

- `no-new-privileges:true` on core services
- Traefik:
  - `cap_drop: ALL`
  - `cap_add: NET_BIND_SERVICE`
  - `read_only: true`
  - `tmpfs: /tmp`
  - `--ping=true` + Docker healthcheck
- Healthchecks on Traefik, Redis, Postgres
- Docker log rotation and memory limits

---

## 2) Scripts Reference (Dev vs Prod)

| Script                                                         | Purpose                                                     | Dev      | Prod        |
| -------------------------------------------------------------- | ----------------------------------------------------------- | -------- | ----------- |
| `scripts/setup.ps1` / `scripts/setup.sh`                       | Bootstrap `.env`, `redis/.users.acl`, auth folder checks    | Yes      | Yes         |
| `scripts/generate-auth.ps1` / `scripts/generate-auth.sh`       | Create `traefik/auth/.htpasswd`                             | Optional | Required    |
| `scripts/add-hosts.ps1`                                        | Add hosts entries from `.env` `DOMAIN` (Windows local only) | Yes      | No          |
| `scripts/manage-redis-acl.ps1` / `scripts/manage-redis-acl.sh` | Add/update per-app Redis ACL users                          | Optional | Recommended |
| `scripts/pg-backup.sh`                                         | Postgres backup; optional S3 upload                         | Optional | Recommended |
| `scripts/setup-traefik-logrotate.sh`                           | Install host logrotate for Traefik `access.log` volume file | No       | Recommended |

Important:

- `add-hosts.ps1` is local machine only, never run on EC2 production host.
- Never commit `.env`, `redis/.users.acl`, `traefik\auth\.htpasswd`.

---

## 3) Bare Minimum Setup

### Local (quick)

```powershell
cd C:\path\to\server-infra
.\scripts\setup.ps1
.\scripts\generate-auth.ps1 -Username admin
.\scripts\add-hosts.ps1
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
docker compose ps
```

### Production (quick)

```bash
cd /opt/server-infra
./scripts/setup.sh
./scripts/generate-auth.sh admin
sudo apt-get update && sudo apt-get install -y logrotate
sudo ./scripts/setup-traefik-logrotate.sh
docker compose up -d
docker compose ps
```

Then immediately:

- set strong secrets in `.env` and `redis/.users.acl`
- set strict `ADMIN_IP_ALLOWLIST`
- verify DNS for admin subdomains
- **Recommended:** configure and enable automated backups now:

```bash
# Optional S3 config in .env: S3_BUCKET, S3_PREFIX, AWS_REGION
./scripts/pg-backup.sh
sudo cp /opt/server-infra/server-infra-pg-backup.service /etc/systemd/system/
sudo cp /opt/server-infra/server-infra-pg-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-infra-pg-backup.timer
systemctl list-timers server-infra-pg-backup.timer
```

Recommended on Linux hosts:

```bash
chmod 600 .env redis/.users.acl traefik/auth/.htpasswd
```

---

## 4) Local Development Setup (Detailed)

Use this only for local testing.

### Step 1: Prerequisites

- Docker Desktop (or Docker Engine + Compose)
- `.env` with `DOMAIN` set (example `local.com`)

### Step 2: Bootstrap files

Windows:

```powershell
cd C:\path\to\server-infra
.\scripts\setup.ps1
```

Linux/macOS:

```bash
cd /path/to/server-infra
./scripts/setup.sh
```

### Step 3: Edit `.env`

Minimum:

```bash
DOMAIN=local.com
PORTAINER_EXPOSE=false
ACME_EMAIL=admin@example.com
ADMIN_IP_ALLOWLIST=127.0.0.1/32

POSTGRES_USER=postgres
POSTGRES_PASSWORD=CHANGE_ME_STRONG
POSTGRES_DB=postgres

PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=CHANGE_ME_STRONG

REDIS_MAXMEMORY=768mb
REDIS_MAXMEMORY_POLICY=noeviction
```

### Step 4: Configure local hosts (Windows helper)

Run as Administrator:

```powershell
.\scripts\add-hosts.ps1
```

It adds:

- `pgadmin.db.<DOMAIN>`
- `redis.db.<DOMAIN>`
- `docker.<DOMAIN>`
- `uptime.<DOMAIN>`
- `traefik.<DOMAIN>`

### Step 5: Start local stack

```powershell
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
docker compose ps
```

Expected healthy services: `traefik`, `redis`, `postgres`.

### Step 6: Access local URLs

- `http://traefik.<DOMAIN>`
- `http://pgadmin.db.<DOMAIN>`
- `http://redis.db.<DOMAIN>`
- `http://uptime.<DOMAIN>`
- `http://docker.<DOMAIN>` (only when Portainer is started)

### Step 7: Portainer maintenance mode

Start (local):

```powershell
docker compose --profile admin -f docker-compose.yml -f docker-compose.local.yml up -d portainer traefik
```

Stop:

```powershell
docker compose stop portainer
```

---

## 5) Production Setup on EC2 (Detailed)

### Step 1: EC2 prerequisites

- Security group inbound:
  - `22` from restricted admin IPs
  - `80`, `443` from internet
- DNS A records -> EC2 IP:
  - `traefik.<DOMAIN>`
  - `pgadmin.db.<DOMAIN>`
  - `redis.db.<DOMAIN>`
  - `uptime.<DOMAIN>`
  - optional `docker.<DOMAIN>`
- Docker + Compose installed

### Step 2: Bootstrap

```bash
cd /opt/server-infra
./scripts/setup.sh
./scripts/generate-auth.sh admin
```

Edit secrets:

- `.env` (domain, DB creds, pgAdmin creds, allowlist)
- `redis/.users.acl` (redis_admin + app users)

Recommended on Linux hosts:

```bash
chmod 600 .env redis/.users.acl traefik/auth/.htpasswd
```

### Step 3: Start production stack

```bash
docker compose up -d
docker compose ps
```

### Step 4: Validate

- Traefik/Redis/Postgres are `healthy`
- admin routes require BasicAuth
- `ADMIN_IP_ALLOWLIST` blocks non-allowed IPs

### Step 5: Portainer maintenance workflow

Enable route in `.env`:

```bash
PORTAINER_EXPOSE=true
```

Start temporarily:

```bash
docker compose --profile admin up -d portainer traefik
```

Stop after maintenance:

```bash
docker compose stop portainer
```

Safe maintenance workflow checklist:

- [ ] Confirm this is an active maintenance window and Portainer is actually needed
- [ ] Ensure `ADMIN_IP_ALLOWLIST` includes only current trusted admin IP/CIDR values
- [ ] Set `PORTAINER_EXPOSE=true` in `.env`
- [ ] Start only required services: `docker compose --profile admin up -d portainer traefik`
- [ ] Verify access through `https://docker.<DOMAIN>` (Traefik BasicAuth + Portainer auth)
- [ ] Perform required maintenance actions and capture notes/screenshots for audit trail
- [ ] Stop Portainer immediately after maintenance: `docker compose stop portainer`
- [ ] Set `PORTAINER_EXPOSE=false` in `.env`
- [ ] Confirm route is no longer exposed (expect 404/unreachable for `docker.<DOMAIN>`)

Reset Portainer admin password if needed:

```bash
docker compose stop portainer
docker run --rm -v portainer-data:/data portainer/helper-reset-password
docker compose --profile admin up -d portainer
```

### Step 6: Recommended backup setup

Configure backup variables in `.env` (if uploading to S3):

```bash
S3_BUCKET=my-server-infra-backups
S3_PREFIX=postgres
AWS_REGION=us-east-1
```

Run an immediate backup test:

```bash
./scripts/pg-backup.sh
```

Enable the systemd timer:

```bash
sudo cp /opt/server-infra/server-infra-pg-backup.service /etc/systemd/system/
sudo cp /opt/server-infra/server-infra-pg-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-infra-pg-backup.timer
systemctl list-timers server-infra-pg-backup.timer
```

### Step 7: Recommended Traefik access log rotation

Docker `json-file` rotation already covers container stdout/stderr logs.
Traefik `access.log` is a separate file in the `traefik-logs` volume and should
be rotated via host `logrotate`.

```bash
sudo apt-get update
sudo apt-get install -y logrotate
sudo ./scripts/setup-traefik-logrotate.sh
sudo logrotate -d /etc/logrotate.d/server-infra-traefik-access
```

---

## 6) Day-2 Operations

### Start / stop / restart

```bash
docker compose up -d
docker compose down
docker compose restart
docker compose restart redis
```

### Logs and status

```bash
docker compose logs -f
docker compose logs -f traefik
docker compose logs --tail=200 postgres
docker compose ps
```

Traefik access logs are written to `/var/log/traefik/access.log` inside the
container and backed by the `traefik-logs` Docker volume on the host. They are
rotated by host `logrotate` when `scripts/setup-traefik-logrotate.sh` is used.

### Common maintenance commands

```bash
# Pull latest infra code and apply changes to running stack
git fetch origin main
git pull --ff-only origin main
docker compose pull
docker compose up -d --remove-orphans
docker compose ps

# Force recreate a single service (refresh labels/mounts/env without full down/up)
docker compose up -d --force-recreate traefik

# Force recreate entire stack
docker compose up -d --force-recreate

# Follow Traefik runtime logs (stdout/stderr)
docker compose logs -f traefik

# Clear all Docker json-file logs (stdout/stderr) for running containers
sudo sh -c 'truncate -s 0 /var/lib/docker/containers/*/*-json.log'

# View Traefik access log from the volume
ACCESS_LOG="$(docker volume inspect traefik-logs -f '{{.Mountpoint}}')/access.log"
sudo tail -f "$ACCESS_LOG"

# Clear only Traefik access log file
sudo truncate -s 0 "$ACCESS_LOG"

# Test and force-run Traefik access logrotate config
sudo logrotate -d /etc/logrotate.d/server-infra-traefik-access
sudo logrotate -f /etc/logrotate.d/server-infra-traefik-access
```

### Basic service checks

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1;"
docker compose exec redis redis-cli ping
```

### Upgrade images

```bash
docker compose pull
docker compose up -d
docker compose ps
```

---

## 7) Redis ACL Operations

### Create/update app user

Linux/macOS:

```bash
./scripts/manage-redis-acl.sh app_one STRONG_PASSWORD app_one
docker compose up -d redis
```

Windows:

```powershell
.\scripts\manage-redis-acl.ps1 -Username app_one -Password STRONG_PASSWORD -Prefix app_one
docker compose up -d redis
```

Guidelines:

- one Redis user per app
- use app-specific key prefix
- do not use `redis_admin` for app runtime traffic

---

## 8) Backups and Restore

### Manual backup

```bash
./scripts/pg-backup.sh
```

Output path:

- `backups/postgres/<timestamp>/`

### Optional S3 upload

Set in `.env`:

```bash
S3_BUCKET=my-server-infra-backups
S3_PREFIX=postgres
AWS_REGION=us-east-1
```

Run backup script:

```bash
./scripts/pg-backup.sh
```

### AWS setup required for S3 backup

1. Create S3 bucket and enable encryption
2. Add retention lifecycle policy
3. Attach IAM role to EC2
4. Role needs:
   - `s3:PutObject`
   - `s3:AbortMultipartUpload`
   - `s3:ListBucket`
5. Install AWS CLI on EC2 host

Example policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::my-server-infra-backups/postgres/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::my-server-infra-backups"
    }
  ]
}
```

### systemd backup job

Files included:

- `server-infra-pg-backup.service`
- `server-infra-pg-backup.timer`

Install:

```bash
sudo cp /opt/server-infra/server-infra-pg-backup.service /etc/systemd/system/
sudo cp /opt/server-infra/server-infra-pg-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-infra-pg-backup.timer
sudo systemctl status server-infra-pg-backup.timer
systemctl list-timers server-infra-pg-backup.timer
```

### Restore examples

```bash
gunzip -c backups/postgres/<timestamp>/globals.sql.gz | docker compose exec -T postgres psql -U postgres postgres
gunzip -c backups/postgres/<timestamp>/app_one.sql.gz | docker compose exec -T postgres psql -U postgres app_one
```

---

## 9) Security Caveats You Must Know

### Mandatory practices

- never commit `.env`, `redis/.users.acl`, `traefik/auth/.htpasswd`
- use strong, unique passwords
- keep `ADMIN_IP_ALLOWLIST` narrow
- do not expose Postgres/Redis ports in production
- run Portainer only during maintenance (`--profile admin`)

### Caveats

- Portainer + Docker socket is high privilege (treat as break-glass)
- Traefik also accesses Docker socket (read-only but sensitive)
- secrets remain plaintext on host files; protect host access and permissions
- container hardening does not replace host hardening (SSH policy, updates, IAM, SG rules)

### Manage permissions

Recommended on Linux hosts for secret files:

```bash
# View current permissions
ls -l .env redis/.users.acl traefik/auth/.htpasswd

# Set strict permissions (owner read/write only)
chmod 600 .env redis/.users.acl traefik/auth/.htpasswd

# Verify
ls -l .env redis/.users.acl traefik/auth/.htpasswd
```

If Docker/service user needs access, adjust file owner/group accordingly instead of loosening file permissions.

---

## 10) Troubleshooting

### Admin URLs not reachable

- verify DNS records and `DOMAIN`
- verify `ADMIN_IP_ALLOWLIST` includes your current IP
- inspect Traefik logs:

```bash
docker compose logs -f traefik
```

### Portainer route gives 404

- confirm `.env` has `PORTAINER_EXPOSE=true`
- start with admin profile:

```bash
docker compose --profile admin up -d portainer traefik
```

### Local domains do not resolve

- run `.\scripts\add-hosts.ps1` as Administrator
- ensure hosts entries match `.env` `DOMAIN`

### Redis/Postgres unhealthy

```bash
docker compose logs --tail=200 redis
docker compose logs --tail=200 postgres
docker compose ps
```

### BasicAuth fails

Regenerate `.htpasswd`:

- Windows: `.\scripts\generate-auth.ps1`
- Linux/macOS: `./scripts/generate-auth.sh`

---

## 11) Extending Infra with New Apps

**Backbone principle:** This server-infra is the single entry point. Traefik is the only reverse proxy: all public HTTP/HTTPS traffic goes through it. Apps (Node APIs, React SPAs, etc.) do not add their own reverse proxy in front of Traefik; they attach to `traefik-network`, expose a port, and register routes via Traefik labels.

Each app should:

- attach to `traefik-network` for HTTP routing
- attach to `backend-network` only if it needs Redis/Postgres
- use app-specific Postgres DB/user and Redis ACL user + prefix when using backend
- define app Traefik labels (Host rule, entrypoints, explicit router->service mapping, service port; TLS defaults come from Traefik `websecure` entrypoint)
- set `traefik.docker.network=traefik-network` on app labels as an explicit safety guard (especially for multi-network containers)

### React / static SPAs

- **Route the React app with Traefik** — same pattern as the Node app. Add a subdomain (e.g. `app.example.com`), point DNS to the server, and use Traefik labels so Traefik routes that host to your React container.
- **Inside the React image**, use a small web server (e.g. nginx or `serve`) only to **serve the built static files** and SPA fallback (e.g. `try_files $uri /index.html`). That server is not a reverse proxy; Traefik remains the only one. The container just needs to listen on one port (e.g. 80); Traefik forwards traffic to it.

Example pattern for a React app’s `docker-compose.yml` (run from infra root with the app’s env):

```yaml
services:
  my-react-app:
    image: your-registry/my-react-app:1.0.0
    networks:
      - traefik-network
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik-network"
      - "traefik.http.routers.my-react-app.rule=Host(`${APP_HOST}`)"
      - "traefik.http.routers.my-react-app.entrypoints=websecure"
      - "traefik.http.routers.my-react-app.service=my-react-app"
      - "traefik.http.services.my-react-app.loadbalancer.server.port=80"
networks:
  traefik-network:
    external: true
```

**Redis user** (from infra root; then `docker compose up -d redis`):

```bash
# Linux/macOS
./scripts/manage-redis-acl.sh my_api "STRONG_PASSWORD" my_api

# Windows
.\scripts\manage-redis-acl.ps1 -Username my_api -Password "STRONG_PASSWORD" -Prefix my_api
```

**Postgres DB and user** (set `APP_DB_NAME`, `APP_DB_USER`, `APP_DB_PASSWORD` then run from infra root):

```bash
docker compose exec postgres psql -U "$POSTGRES_USER" -d postgres -c "
  CREATE USER ${APP_DB_USER} WITH PASSWORD '${APP_DB_PASSWORD}';
  CREATE DATABASE ${APP_DB_NAME} OWNER ${APP_DB_USER};
  GRANT CONNECT ON DATABASE ${APP_DB_NAME} TO ${APP_DB_USER};
  GRANT ALL PRIVILEGES ON DATABASE ${APP_DB_NAME} TO ${APP_DB_USER};
"
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$APP_DB_NAME" -c "
  GRANT ALL ON SCHEMA public TO ${APP_DB_USER};
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${APP_DB_USER};
  GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${APP_DB_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${APP_DB_USER};
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${APP_DB_USER};
"
```

**Deploy:**

```bash
docker compose -f apps/my-app/docker-compose.yml --env-file apps/my-app/.env up -d
```

---

## 12) File Layout

```text
server-infra/
├── docker-compose.yml
├── docker-compose.local.yml
├── .env.example
├── hosts-entries.txt
├── server-infra-pg-backup.service
├── server-infra-pg-backup.timer
├── redis/
│   ├── .users.acl.example
│   └── README.md
├── traefik/auth/
│   └── .htpasswd.example
├── scripts/
│   ├── setup.ps1 / setup.sh
│   ├── generate-auth.ps1 / generate-auth.sh
│   ├── manage-redis-acl.ps1 / manage-redis-acl.sh
│   ├── add-hosts.ps1
│   ├── pg-backup.sh
│   └── setup-traefik-logrotate.sh
└── apps/
    └── example-app/
```
