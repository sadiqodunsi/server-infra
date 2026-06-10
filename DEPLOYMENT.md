# Deployment Guide (GitHub Actions)

Automated deploys for the server-infra Docker stack via GitHub Actions. Push to `stage` or `main` to deploy; no manual `git pull` or `docker build` on the server.

All services use **version-pinned public images** (Traefik, Redis, Uptime Kuma, PostGIS, etc.). There are no custom Dockerfiles and no GHCR build step today.

---

## Branch / trigger behavior

| Event | Action |
| ----- | ------ |
| PR → `main` / `stage` | CI validate only (compose + shellcheck) |
| Push → `stage` | Deploy to GitHub Environment `staging` |
| Push → `main` | Deploy to GitHub Environment `production` |
| `workflow_dispatch` | Manual deploy to chosen environment |

---

## Bootstrap checklist (before first deploy)

Complete these steps **on each EC2 instance** before the first successful auto-deploy. The pipeline does not run `setup.sh` or create secrets.

### 1. GitHub configuration

Create Environments **`staging`** and **`production`** in repo Settings → Environments. Add secrets and variables per the tables below.

### 2. Server prerequisites

```bash
# Create deploy directory
sudo mkdir -p /opt/platform/server-infra
sudo chown $USER:$USER /opt/platform/server-infra
cd /opt/platform/server-infra

# Clone once to get setup scripts (or skip and use first rsync from a partial deploy)
git clone <your-repo-url> .

# One-time bootstrap
./scripts/setup.sh
./scripts/generate-auth.sh admin
chmod 600 .env redis/.users.acl
chmod 755 traefik/auth
chmod 644 traefik/auth/.htpasswd
```

Edit `.env` with real values:

- `DOMAIN`, `INFRA_HOST_SUFFIX`, `ACME_EMAIL`, `ADMIN_IP_ALLOWLIST`
- `COMPOSE_FILE` — production: `docker-compose.yml:docker-compose.admin.yml`; staging: `docker-compose.yml:docker-compose.staging.yml:docker-compose.admin.yml`
- Postgres/pgAdmin vars (staging only)
- Redis memory settings

Ensure Docker Engine + Compose plugin are installed and the deploy user is in the `docker` group.

### 3. Authorize deploy SSH key

Add the public key matching `SSH_PRIVATE_KEY` to the deploy user's `~/.ssh/authorized_keys`.

### 4. First auto-deploy

Push to `stage` or `main`, or trigger **Deploy (Docker)** via `workflow_dispatch`. The workflow will rsync files, `docker compose pull`, and `docker compose up -d --wait --no-build`.

---

## GitHub Environments

Create **`staging`** and **`production`** in Settings → Environments. Staging and production target **different EC2 instances** via per-environment `SSH_HOST`.

### Secrets (per environment)

| Secret | Required | Purpose |
| ------ | -------- | ------- |
| `SSH_PRIVATE_KEY` | Yes | Deploy SSH private key |
| `SSH_USER` | Yes | SSH user (e.g. `ubuntu`) |
| `SSH_HOST` | Yes | EC2 hostname or IP (**different per env**) |
| `SSH_KNOWN_HOSTS` | Yes | Pinned host key line for `SSH_HOST` |
| `GHCR_PAT` | No | Only if you add private GHCR images later |
| `GHCR_USERNAME` | No | Defaults to repo owner if GHCR is used |

### Environment variables (per environment)

| Variable | Example (staging) | Example (production) | Purpose |
| -------- | ----------------- | -------------------- | ------- |
| `DEPLOY_PATH` | `/opt/platform/server-infra` | `/opt/platform/server-infra` | Remote deploy directory |
| `ENV_FILE` | `.env` | `.env` | Env file name under `DEPLOY_PATH` |
| `HEALTHCHECK_HOST` | `uptime-staging.example.com` | `uptime.example.com` | Uptime Kuma hostname for post-deploy curl |

### GitHub repo settings checklist

- [ ] Environments `staging` and `production` created (optional protection rules on `production`)
- [ ] Secrets and variables configured per tables above
- [ ] Deploy SSH public key authorized on each EC2 instance
- [ ] Workflow permissions: `contents: read` (no `packages: write` needed today)

---

## What gets synced vs stays on the server

**Synced on each deploy (via rsync):**

- `docker-compose.yml`, `docker-compose.staging.yml`, `docker-compose.admin.yml`
- `postgres/initdb/`
- `scripts/`
- `server-infra-pg-backup.service`, `server-infra-pg-backup.timer`

**Never synced (server-local secrets):**

- `.env` (or whatever `ENV_FILE` points to)
- `traefik/auth/.htpasswd`
- `redis/.users.acl`

**Not synced:** `docker-compose.local.yml`, `apps/` (examples only)

---

## What happens on each deploy

1. **Validate** — `docker compose config` for production and staging stacks; `shellcheck` on `scripts/*.sh`
2. **SSH** — connect to the target EC2 (staging or production per branch / manual input)
3. **Rsync** — sync compose files, init scripts, and helper scripts (secrets untouched)
4. **Pull** — `docker compose --env-file $ENV_FILE pull` (public images from Docker Hub, etc.)
5. **Up** — `docker compose --env-file $ENV_FILE up -d --wait --no-build` (recreates changed containers)
6. **Health check** — curl `https://$HEALTHCHECK_HOST`; HTTP 200, 401, or 302 = pass (401 is expected behind Traefik BasicAuth)

Admin-profile services (`redisinsight`, `portainer`) are **not** started by deploy. Use `--profile admin` on the server when needed (see README).

The pipeline never runs `docker compose down`, so `traefik-network` and `backend-network` stay up for attached app containers (e.g. viscorner-backend).

---

## Day-to-day operations

After bootstrap, routine infra changes require **no SSH**:

- Merge compose or config changes to `stage` or `main`
- GitHub Actions deploys automatically

You still SSH manually when:

- Changing secrets (`.env`, Redis ACL, BasicAuth)
- Starting admin tools: `docker compose --profile admin up -d redisinsight portainer traefik`
- Updating `ADMIN_IP_ALLOWLIST` (edit `.env`; next deploy or `docker compose up -d traefik` applies it)

---

## Server one-time setup details

1. Docker Engine + Compose plugin; deploy user in `docker` group
2. `/opt/platform/server-infra` owned by deploy user
3. `scripts/setup.sh` + `scripts/generate-auth.sh`; strong secrets in `.env`, `redis/.users.acl`, `traefik/auth/.htpasswd`
4. `COMPOSE_FILE` in `.env` per environment (see `.env.example`)
5. DNS A records for admin subdomains; security group: 22 (restricted), 80, 443
6. **Staging only:** systemd backup timer (`server-infra-pg-backup.*`)
7. **Production:** managed Postgres for apps (no Docker `postgres` service)
8. **Production:** `logrotate` + `./scripts/setup-traefik-logrotate.sh`

---

## Manual rollback

Re-run the deploy workflow on a previous commit (Actions → Deploy (Docker) → Re-run), or on the server:

```bash
cd /opt/platform/server-infra
docker compose --env-file .env pull
docker compose --env-file .env up -d --wait --no-build
./scripts/verify-ec2.sh
```

To roll back image versions, pin older tags in the compose files in git and redeploy.

---

## Integration with viscorner-backend

- **Deploy order:** infra first, then backend
- Infra deploy uses `up -d` only — never `down` on shared hosts
- Backend uses its own GHCR-built images and `REGISTRY_IMAGE` digest pinning independently
- Apps attach to `traefik-network` and `backend-network` created by this stack

---

## Future: custom images via GHCR

If you add a custom Dockerfile (e.g. extended PostGIS), add a CI build/push job and set `REGISTRY_IMAGE` (or per-service vars) in the server `.env`, following the viscorner-backend pattern. Until then, immutability comes from version-pinned public image tags in compose.
