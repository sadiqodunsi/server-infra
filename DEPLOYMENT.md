# Deployment Guide

How this infrastructure is hosted, updated, and validated.

**Deploy model (default):** you SSH to each host, `git pull`, then `docker compose pull` / `docker compose up -d`. GitHub Actions runs CI and publishes the staging Postgres image to GHCR; it does **not** update servers unless you enable [auto-deploy](#auto-deploy-via-github-actions-optional--disabled-by-default) at the bottom of this guide.

For day-to-day commands (compose files, maintenance UIs, backups, troubleshooting), see [README.md](README.md).

---

## Where things run

| Environment | Host | Compose files | Postgres | Typical path on server |
| ----------- | ---- | ------------- | -------- | ---------------------- |
| **Local** | Docker Desktop | `docker-compose.yml` + `staging` + `local` + `admin` | Docker (`POSTGRES_IMAGE` from GHCR) | your clone |
| **Staging** | EC2 | `docker-compose.yml` + `staging` + `admin` | Docker (`POSTGRES_IMAGE` from GHCR) | e.g. `/opt/platform/server-infra` |
| **Production** | EC2 | `docker-compose.yml` + `admin` | Managed off-host (RDS, etc.) — **no** Docker `postgres` service | e.g. `/opt/platform/server-infra` |

Staging and production are **separate EC2 instances** (different IPs, different `.env` files).

**Always-on services**

- **Staging:** `traefik`, `redis`, `postgres`, `pgadmin`, `uptime-kuma`
- **Production:** `traefik`, `redis`, `uptime-kuma` (no `postgres`, no `pgadmin`)

**Maintenance profile (`--profile admin`):** `redisinsight`, `portainer` — all environments; not started by default.

**Networks (created by this stack, shared with apps):**

- `traefik-network` — ingress / reverse proxy
- `backend-network` — Redis, Postgres (staging), app containers

Apps (e.g. viscorner-backend) attach to these external networks. Infra deploy uses `docker compose up -d` only — never `docker compose down` on shared hosts.

---

## GitHub Actions (CI only — does not deploy)

### What runs when

| Event | CI (`ci.yml` → `validate.yml`) | Build Postgres image (`build-postgres.yml`) |
| ----- | ------------------------------ | ------------------------------------------- |
| PR → `main` / `stage` | Compose config + shellcheck | Build Dockerfile only — **does not push** to GHCR |
| Push → `main` / `stage` | Same | Build **and push** to GHCR |
| Actions → **Build Postgres image** (manual) | No | Build **and push** to GHCR |

Nothing in Actions updates a running server. After merge, you still deploy manually on the host.

### Why PRs do not push the image

A PR is unmerged work. Pushing from a PR would overwrite `ghcr.io/.../postgres:16-3.5-pgvector` with code that might never land. PRs only prove the Dockerfile builds; publish happens on push to `main` / `stage`.

`GITHUB_TOKEN` is automatic in Actions (do not add it as a secret). The build job needs `packages: write` to push to GHCR.

### GitHub configuration for CI

No GitHub **Environments** (`staging` / `production`) are required for CI or image publish.

Optional repo setting: **Settings → Actions → General → Workflow permissions → Read and write** (so `GITHUB_TOKEN` can push packages).

---

## Staging Postgres image (GHCR)

PostGIS + pgvector are not in a single public Hub image. CI builds `postgres/Dockerfile` and publishes:

- `ghcr.io/<owner>/server-infra/postgres:16-3.5-pgvector` — moving tag (what you normally use)
- `ghcr.io/<owner>/server-infra/postgres:sha-<git-sha>` — frozen per commit

Set in **local** and **staging server** `.env`:

```bash
POSTGRES_IMAGE=ghcr.io/sadiqodunsi/server-infra/postgres:16-3.5-pgvector
```

Production does not use this (managed Postgres).

**First time:** merge to `main` or `stage` so CI publishes the image, or run **Build Postgres image** manually in Actions. Until the image exists on GHCR, `docker compose pull` for `postgres` will fail.

**Public repo → public GHCR package** by default; no `docker login` needed on the host. If the package is private, run `docker login ghcr.io` on the server before `docker compose pull`.

**Rollback / pin a build:** change `POSTGRES_IMAGE` to `sha-<commit>` or `@sha256:...`, then `docker compose pull` and `up -d`.

---

## Bootstrap checklist (each EC2 host)

Complete once per server before routine deploys.

### 1. Server prerequisites

```bash
sudo mkdir -p /opt/platform/server-infra
sudo chown $USER:$USER /opt/platform/server-infra
cd /opt/platform/server-infra

git clone <your-repo-url> .

./scripts/setup.sh
./scripts/generate-auth.sh admin
chmod 600 .env redis/.users.acl
chmod 755 traefik/auth
chmod 644 traefik/auth/.htpasswd
```

Ensure Docker Engine + Compose plugin are installed and your user is in the `docker` group.

### 2. Edit server `.env`

Never commit this file. Per host:

| Setting | Staging | Production |
| ------- | ------- | ---------- |
| `COMPOSE_FILE` | `docker-compose.yml:docker-compose.staging.yml:docker-compose.admin.yml` | `docker-compose.yml:docker-compose.admin.yml` |
| `DOMAIN`, `INFRA_HOST_SUFFIX`, `ACME_EMAIL`, `ADMIN_IP_ALLOWLIST` | Yes | Yes |
| `POSTGRES_IMAGE`, `POSTGRES_*`, `PGADMIN_*` | Yes | No (managed Postgres for apps) |
| `REDIS_MAXMEMORY`, `REDIS_MAXMEMORY_POLICY` | Yes | Yes |
| `PORTAINER_EXPOSE` | As needed | `false` unless maintenance |

See `.env.example` for the full list.

### 3. DNS and security group

- Inbound: `22` (restricted), `80`, `443`
- A records to the host IP: `traefik<suffix>.<domain>`, `uptime<suffix>.<domain>`, staging also `pgadmin<suffix>.<domain>`

### 4. Staging only — backups

```bash
# Optional S3 in .env: S3_BUCKET, S3_PREFIX, AWS_REGION
./scripts/pg-backup.sh
sudo cp server-infra-pg-backup.service /etc/systemd/system/
sudo cp server-infra-pg-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-infra-pg-backup.timer
```

### 5. Production only

- Managed Postgres for apps (not `postgres:5432` in Docker)
- Host logrotate: `./scripts/setup-traefik-logrotate.sh`

### 6. Publish Postgres image (staging / local)

Push to `main` or `stage`, or run **Build Postgres image** in Actions once. Confirm `POSTGRES_IMAGE` in `.env` matches the published tag.

---

## Server one-time setup details

Checklist after bootstrap on each EC2 host (see [Bootstrap checklist](#bootstrap-checklist-each-ec2-host) above for commands):

1. Docker Engine + Compose plugin; deploy user in the `docker` group
2. `/opt/platform/server-infra` (or your path) owned by the deploy user
3. `scripts/setup.sh` + `scripts/generate-auth.sh`; strong secrets in `.env`, `redis/.users.acl`, `traefik/auth/.htpasswd`
4. `COMPOSE_FILE` in `.env` per environment (see `.env.example`)
5. **Staging only:** `POSTGRES_IMAGE` pointing at the GHCR image tag (or digest)
6. DNS A records for admin subdomains; security group: `22` (restricted), `80`, `443`
7. **Staging only:** systemd backup timer (`server-infra-pg-backup.*`)
8. **Production:** managed Postgres for apps (no Docker `postgres` service)
9. **Production:** `logrotate` + `./scripts/setup-traefik-logrotate.sh`

**If you enable auto-deploy later:** authorize the deploy SSH public key on each host (`~/.ssh/authorized_keys`) and configure GitHub Environments per [Auto-deploy](#auto-deploy-via-github-actions-optional--disabled-by-default).

---

## Manual deploy (routine)

After merging changes to `main` or `stage`, on the target host:

```bash
cd /opt/platform/server-infra   # or your deploy path

git fetch origin
git pull --ff-only origin main    # or origin stage on staging host

docker compose pull
docker compose up -d
docker compose ps
```

With `COMPOSE_FILE` set in `.env`, plain `docker compose` is enough. Otherwise pass `-f` flags as in [README.md](README.md).

**Recreate one service** (e.g. after label or env change):

```bash
docker compose up -d --force-recreate traefik
```

**Verify:**

```bash
./scripts/verify-ec2.sh
```

### Staging-specific notes

- Pulls `POSTGRES_IMAGE` from GHCR along with Traefik, Redis, pgAdmin, etc.
- Changing `postgres/Dockerfile` requires a merge to `main`/`stage` first so GHCR has a new image, then `git pull` + `docker compose pull` + `up -d` on the server.
- Existing Postgres volumes are **not** re-initialized when the image changes. Enable `vector` in app DBs manually if needed (`CREATE EXTENSION IF NOT EXISTS vector;`). See README.

### Production-specific notes

- No Docker Postgres service; apps use managed Postgres connection strings.
- Infra changes are still `git pull` + `docker compose pull` + `up -d`.

---

## What lives on the server vs in git

**In git (updated via `git pull`):**

- `docker-compose.yml`, `docker-compose.staging.yml`, `docker-compose.admin.yml`
- `postgres/Dockerfile`, `postgres/initdb/`
- `scripts/`
- `server-infra-pg-backup.service`, `server-infra-pg-backup.timer`

**On the server only (never committed):**

- `.env`
- `traefik/auth/.htpasswd`
- `redis/.users.acl`

**Not used on servers:**

- `docker-compose.local.yml` (local dev only)
- `apps/` (examples)

**Docker volumes (persist across container recreates):**

- `postgres-data`, `redis-data`, `traefik-letsencrypt`, `traefik-logs`, `pgadmin-data`, `uptime-kuma-data`, etc.

Back up volumes / use `pg-backup.sh` on staging for Postgres.

---

## Day-to-day operations

You SSH manually for:

- Deploying infra changes (`git pull`, compose pull/up)
- Secret changes (`.env`, Redis ACL, BasicAuth)
- Pinning `POSTGRES_IMAGE` to a digest or `sha-<commit>`
- Admin tools: `docker compose --profile admin up -d redisinsight portainer traefik`
- `ADMIN_IP_ALLOWLIST` updates (edit `.env`, then `docker compose up -d traefik`)

---

## Rollback

**Compose / config:** check out an older commit or `git pull` a previous revision, then `docker compose pull` and `up -d`.

**Postgres image only:** in `.env`:

```bash
POSTGRES_IMAGE=ghcr.io/OWNER/server-infra/postgres:sha-<commit>
# or
POSTGRES_IMAGE=ghcr.io/OWNER/server-infra/postgres@sha256:...
```

Then:

```bash
docker compose pull
docker compose up -d
./scripts/verify-ec2.sh
```

---

## Integration with viscorner-backend

- **Order:** infra stack up first (networks exist), then backend compose.
- Backend uses its own GHCR images and env; not deployed by this repo's workflows.
- Apps join `traefik-network` and `backend-network` created here.
- Use `up -d` only on shared hosts — do not `docker compose down` the infra project while apps are attached.

---

## Auto-deploy via GitHub Actions (optional — disabled by default)

The Deploy (Docker) workflow (`.github/workflows/deploy.yml`) can SSH to your EC2 hosts, rsync files, pull images, and `docker compose up -d` automatically on push to `main` / `stage`. It is **disabled** — the `push:` trigger is commented out. You can still run it manually via `workflow_dispatch` in Actions.

To enable auto-deploy:

### 1. Create GitHub Environments

Create **`staging`** and **`production`** in repo **Settings → Environments**. Each targets a different EC2 instance.

### 2. Add secrets (per environment)

| Secret | Required | Purpose |
| ------ | -------- | ------- |
| `SSH_PRIVATE_KEY` | Yes | Deploy SSH private key |
| `SSH_USER` | Yes | SSH user (e.g. `ubuntu`) |
| `SSH_HOST` | Yes | EC2 hostname or IP (**different per env**) |
| `SSH_KNOWN_HOSTS` | Yes | Pinned host key line for `SSH_HOST` |
| `GHCR_PAT` | Staging only (if GHCR package is private) | PAT with `read:packages` so the EC2 host can pull private GHCR images |
| `GHCR_USERNAME` | No | GHCR login user; defaults to repo owner |

### 3. Add variables (per environment)

| Variable | Example (staging) | Example (production) | Purpose |
| -------- | ----------------- | -------------------- | ------- |
| `DEPLOY_PATH` | `/opt/platform/server-infra` | `/opt/platform/server-infra` | Remote deploy directory |
| `ENV_FILE` | `.env` | `.env` | Env file name under `DEPLOY_PATH` |
| `HEALTHCHECK_HOST` | `uptime-staging.example.com` | `uptime.example.com` | Uptime Kuma hostname for post-deploy curl |

### 4. Set workflow permissions

**Settings → Actions → General → Workflow permissions → Read and write** (so `GITHUB_TOKEN` can push packages and the deploy job can read environment secrets).

### 5. Uncomment the push trigger

In `.github/workflows/deploy.yml`, uncomment:

```yaml
  push:
    branches:
      - main
      - stage
```

After this, pushing to `stage` deploys staging (including building + pushing the Postgres image first); pushing to `main` deploys production.

### What happens on each auto-deploy

1. **Validate** — `docker compose config` + `shellcheck`
2. **Build Postgres** (staging only) — push image to GHCR
3. **SSH** — connect to the target EC2
4. **Rsync** — sync compose files, scripts, init SQL (secrets untouched)
5. **GHCR login** (staging, if `GHCR_PAT` is set) — `docker login ghcr.io` on the server
6. **Pull** — `docker compose pull`
7. **Up** — `docker compose up -d --wait --no-build`
8. **Health check** — curl the Uptime Kuma host

The workflow never runs `docker compose down`, so `traefik-network` and `backend-network` stay up for attached app containers.

### Authorize deploy SSH key

Add the public key matching `SSH_PRIVATE_KEY` to the deploy user's `~/.ssh/authorized_keys` on each EC2 instance.

### GitHub repo settings checklist

- [ ] Environments `staging` and `production` created (optional protection rules on `production`)
- [ ] Secrets and variables configured per tables above
- [ ] **Staging:** `POSTGRES_IMAGE` set in server `.env`; `GHCR_PAT` only if the GHCR package is private
- [ ] Deploy SSH public key authorized on each EC2 instance
- [ ] Workflow permissions: `contents: read`, `packages: write`
- [ ] `push:` trigger uncommented in `.github/workflows/deploy.yml`

### What gets synced vs stays on the server (auto-deploy)

When Deploy (Docker) runs, **rsync** updates these on the host (secrets untouched):

- `docker-compose.yml`, `docker-compose.staging.yml`, `docker-compose.admin.yml`
- `postgres/Dockerfile`, `postgres/initdb/`
- `scripts/`
- `server-infra-pg-backup.service`, `server-infra-pg-backup.timer`

**Never synced:** `.env`, `traefik/auth/.htpasswd`, `redis/.users.acl`

**Not synced:** `docker-compose.local.yml`, `apps/` (examples)

Manual deploy uses `git pull` instead of rsync; the same file split applies (see [What lives on the server vs in git](#what-lives-on-the-server-vs-in-git)).

---

## Quick reference

| Task | Where |
| ---- | ----- |
| Compose file matrix | [README.md — Compose command reference](README.md) |
| Local Docker Desktop setup | [README.md — Local setup](README.md) |
| Staging / prod EC2 setup | [README.md §5–6](README.md) |
| PostGIS / pgvector in a DB | [README.md — PostGIS and pgvector](README.md) |
| Redis ACL users | [README.md §8](README.md) |
| Postgres backups | [README.md](README.md), `scripts/pg-backup.sh` |
