# Redis ACL Guide

This folder contains Redis ACL files for optional per-app Redis credentials.

## Files

- `.users.acl` - local ACL file used by Redis
- `.users.acl.example` - starter example

`.users.acl` is ignored by git.

## Default behavior

Redis runs with the `default` user disabled.

All Redis users are defined directly in `redis/.users.acl`.

In an ACL line like `user redis_admin on >my-password ...`, the password is the value immediately after `>`.

Use:

- `redis_admin` for RedisInsight and infra access
- named ACL users in `redis/.users.acl` for apps

Expected top entries in `redis/.users.acl`:

```text
user default off resetkeys resetchannels -@all
user redis_admin on >CHANGE_ME_REDIS_ADMIN_PASSWORD ~* &* +@all -@dangerous +info
```

## App key prefixes

Keep each app under its own Redis key prefix.

Examples:

- cache keys: `app_one:cache:user:123`
- BullMQ keys with prefix `app_one`: `app_one:queue:emails:*`

## ACL pattern examples

Example user for app cache and BullMQ with prefix `app_one`:

```text
user app_one on >CHANGE_ME_APP_ONE_PASSWORD ~app_one:* &* +@all -@dangerous +info
```

Example user for another app:

```text
user app_two on >CHANGE_ME_APP_TWO_PASSWORD ~app_two:* &* +@all -@dangerous +info
```

## Helper scripts

Linux / Mac / WSL / Git Bash:

```bash
./scripts/manage-redis-acl.sh app_one STRONG_PASSWORD app_one
```

Windows PowerShell:

```powershell
.\scripts\manage-redis-acl.ps1 -Username app_one -Password STRONG_PASSWORD -Prefix app_one
```

If `Prefix` is omitted, the username is used.

## Apply ACL changes

After updating `redis/.users.acl`, restart Redis:

```bash
docker compose up -d redis
```

## Secure `.users.acl`

- `redis/.users.acl` contains plaintext Redis ACL passwords
- keep it out of git
- edit it only on trusted machines or directly on the server
- restrict file permissions on the server, for example `chmod 600 redis/.users.acl`
- treat it like any other secret file
- use `redis_admin` only for infra access, not for app traffic

## App env example

```bash
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_USERNAME=app_one
REDIS_PASSWORD=STRONG_PASSWORD
REDIS_PREFIX=app_one
```

For BullMQ, set the queue prefix to match `REDIS_PREFIX`.

## ioredis example

```ts
import Redis from "ioredis";

const redis = new Redis({
  host: process.env.REDIS_HOST ?? "redis",
  port: Number(process.env.REDIS_PORT ?? 6379),
  username: process.env.REDIS_USERNAME ?? "app_one",
  password: process.env.REDIS_PASSWORD,
  keyPrefix: `${process.env.REDIS_PREFIX ?? "app_one"}:`,
});
```

Example cache key:

```ts
await redis.set("cache:user:123", JSON.stringify(user), "EX", 300);
```

With `REDIS_PREFIX=app_one`, Redis stores that as:

```text
app_one:cache:user:123
```

## BullMQ example

```ts
import { Queue, Worker } from "bullmq";
import IORedis from "ioredis";

const connection = new IORedis({
  host: process.env.REDIS_HOST ?? "redis",
  port: Number(process.env.REDIS_PORT ?? 6379),
  username: process.env.REDIS_USERNAME ?? "app_one",
  password: process.env.REDIS_PASSWORD,
});

const prefix = process.env.REDIS_PREFIX ?? "app_one";

export const emailQueue = new Queue("emails", {
  connection,
  prefix,
});

export const emailWorker = new Worker(
  "emails",
  async (job) => {
    // handle job
  },
  {
    connection,
    prefix,
  },
);
```

With `REDIS_PREFIX=app_one`, BullMQ keys stay under the `app_one:*` ACL pattern.
