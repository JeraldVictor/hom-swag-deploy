# HomSwag Deploy

Deployment workspace for running the full HomSwag stack with Podman/Docker Compose.

## What this folder does

- Pulls/clones app repositories into `repos/`
- Builds images for `server`, `admin`, and `app`
- Starts infrastructure (`mongodb`, `redis`, `minio`) and application containers
- Supports environment profiles (`local`, `prod`)
- Supports deploying only selected services

---

## Prerequisites

- `podman` (preferred) or `docker`
- `git`
- Access to these repositories:
  - `REPO_SERVER`
  - `REPO_ADMIN`
  - `REPO_APP`

---

## Environment profiles

Use one of these files:

- `.env.local` → local/dev values
- `.env.prod` → production values

The script accepts profile selection with:

- `--env local`
- `--env prod`

If no profile is passed, it defaults to `local`.

### Data storage mounts (MongoDB / MinIO)

You can choose named volumes or host bind paths using env vars:

- `MONGODB_DATA_SOURCE`
- `MINIO_DATA_SOURCE`

Behavior:

- Empty/unset value → uses named volumes (`mongodb-data`, `minio-data`)
- Absolute path value → bind-mounts that host path

Current defaults:

- `.env.local` keeps both empty (Podman/Docker named volumes)
- `.env.prod` sets:
  - `MONGODB_DATA_SOURCE=/app/mongodata`
  - `MINIO_DATA_SOURCE=/app/miniodata`

### Current production domains

- Client app: `https://alpha.homswag.com`
- Admin: `https://admin.alpha.homswag.com`
- API: `https://api.alpha.homswag.com`

### Nginx TLS routing

- Reverse proxy config: `nginx/prod.conf`
- Public ports are served by the `nginx` service on `80` and `443`
- Certificates are mounted from `NGINX_CERTS_PATH` (default: `./nginx/certs`)
- Expected cert files:
  - `nginx/certs/alpha.homswag.com/fullchain.pem`
  - `nginx/certs/alpha.homswag.com/privkey.pem`
  - `nginx/certs/admin.alpha.homswag.com/fullchain.pem`
  - `nginx/certs/admin.alpha.homswag.com/privkey.pem`
  - `nginx/certs/api.alpha.homswag.com/fullchain.pem`
  - `nginx/certs/api.alpha.homswag.com/privkey.pem`

---

## Commands

```bash
./deploy.sh [--env local|prod] [deploy|pull|build|up|restart|logs|status|down] [server|admin|app|all]
```

### Full deploy

```bash
./deploy.sh --env local deploy
./deploy.sh --env prod deploy
```

### Deploy only one app

```bash
./deploy.sh --env local deploy app
./deploy.sh --env prod deploy admin
./deploy.sh --env prod deploy server
```

### Step-by-step

```bash
./deploy.sh --env local pull
./deploy.sh --env local build
./deploy.sh --env local up
```

### Service-specific step-by-step

```bash
./deploy.sh --env prod pull server
./deploy.sh --env prod build server
./deploy.sh --env prod up server
```

### Operations

```bash
./deploy.sh --env prod restart app
./deploy.sh --env prod logs server
./deploy.sh --env prod status
./deploy.sh --env prod down
```

---

## Notes on secrets

- Replace placeholder secrets in `.env.prod` before production deploy.
- Keep `.env.prod` out of public source control.
- At minimum, set strong values for:
  - `MONGO_PASSWORD`
  - `REDIS_PASSWORD`
  - `MINIO_ROOT_PASSWORD`
  - `JWT_SECRET`
  - `JWT_REFRESH_SECRET`

Example secret generation:

```bash
openssl rand -hex 32
```

---

## Ports (default)

- Server: `3000`
- Admin: `3001`
- App: `3002`
- MongoDB: `27017`
- Redis: `6379`
- MinIO API: `9000`
- MinIO Console: `9001`

---

## Troubleshooting

- Validate script syntax:

```bash
bash -n deploy.sh
```

- Verify containers:

```bash
./deploy.sh --env local status
```

- Check logs:

```bash
./deploy.sh --env local logs
```
