# HomSwag Deploy

Deployment workspace for running the full HomSwag stack with Podman/Docker Compose.

## What this folder does

- Uses app sources from `repos/` when present, or from the sibling workspace folders
- Builds images for `server`, `reporting`, `admin`, `app`, and `kafka`
- Pulls/deploys production application images from DigitalOcean Container Registry
- Pushes release images to `registry.digitalocean.com/homswag-repo` only when requested
- Starts infrastructure (`mongodb`, `redis`, `minio`, `kafka`) and application containers
- Serves public traffic through the compose-managed `nginx` container with SSL
- Supports environment profiles (`local`, `prod`)
- Supports deploying only selected services

---

## Prerequisites

- `podman` (preferred) or `docker`
- `git`
- Access to these repositories:
  - `REPO_SERVER`
  - `REPO_REPORTING`
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
- Reporting: `https://reporting.alpha.homswag.com`

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
  - `nginx/certs/reporting.alpha.homswag.com/fullchain.pem`
  - `nginx/certs/reporting.alpha.homswag.com/privkey.pem`

---

## Commands

### Build and push release images

Build images locally:

```bash
./build-images.sh --env prod
```

Build and push to DigitalOcean Container Registry:

```bash
./build-images.sh --env prod --push
```

Build selected services:

```bash
./build-images.sh --env prod server reporting --push
./build-images.sh --env prod --tag 2026.06.15 --push
```

The build script defaults to these registries:

```bash
IMAGE_REGISTRY=docker.io/jeraldvictor
PUSH_REGISTRY=registry.digitalocean.com/homswag-repo
KAFKA_IMAGE_TAG=latest
KAFKA_SOURCE_IMAGE=apache/kafka:latest
KAFKA_PLATFORM=linux/amd64
```

Override the build/deploy pull source with `IMAGE_REGISTRY`.
Override the push target with `PUSH_REGISTRY` or `./build-images.sh --push-registry ...`.
Kafka is pulled from `KAFKA_SOURCE_IMAGE`, then tagged as
`IMAGE_REGISTRY/hom-swag-kafka:KAFKA_IMAGE_TAG`. `KAFKA_PLATFORM` controls
which platform variant is repacked and pushed.

For production deploys, `.env.prod` sets:

```bash
IMAGE_REGISTRY=registry.digitalocean.com/homswag-repo
PUSH_REGISTRY=registry.digitalocean.com/homswag-repo
```

### Deploy existing images

```bash
./deploy.sh [--env local|prod] \
            [deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|status|health|seed|seed-reports]
```

### Full deploy

Global flags may be placed before *or* after the command name; the script
will ignore them when determining which services to act on.

```bash
./deploy.sh --env local deploy
./deploy.sh --env prod deploy
```

Production deploy is graceful: it pulls images, scales app services up behind
nginx, verifies the SSL routes, removes old-image containers, and settles back
to the configured replica counts.

```bash
SERVER_REPLICAS=1
REPORTING_REPLICAS=1
ADMIN_REPLICAS=1
APP_REPLICAS=1
DEPLOY_REPLICAS=2
```

### Clean deploy

Clean deploy removes the compose stack first, pulls fresh images, starts from
scratch, validates health, then prunes old images.

```bash
./deploy.sh --env prod clean
```

In production, `CLEAN_REMOVE_VOLUMES=true` also removes compose-managed named
volumes. Host bind mounts such as `/podLogs/...` are not deleted by Docker.

### Deploy only one app

```bash
./deploy.sh --env local deploy app
./deploy.sh --env prod deploy admin
./deploy.sh --env prod deploy server
```

### Step-by-step

```bash
./deploy.sh --env local pull
./build-images.sh --env local           # add --no-cache to force a clean build
./deploy.sh --env local up
```

### Service-specific step-by-step

```bash
./deploy.sh --env prod pull server
./build-images.sh --env prod server --push
./deploy.sh --env prod up server
```

### Kafka container

Kafka is included in the default build command:

```bash
./build-images.sh --env prod
./build-images.sh --env prod --push
```

You can also build only Kafka:

```bash
./build-images.sh --env prod kafka
./build-images.sh --env prod kafka --push
```

Then pull or refresh it during deploy:

```bash
./deploy.sh --env prod pull kafka
./deploy.sh --env prod up kafka
./deploy.sh --env prod refresh kafka
```

When `server`, `reporting`, and `kafka` share the compose network, keep:

```bash
KAFKA_BOOTSTRAP_SERVERS=kafka:9092
KAFKA_BROKERS=kafka:9092
KAFKA_INTERNAL_HOST=kafka
```

If Kafka is deployed as a separately managed service, set `KAFKA_BOOTSTRAP_SERVERS`
and `KAFKA_BROKERS` to that service DNS name.

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

- HTTP: `80`
- HTTPS: `443`
- MongoDB: `27017`
- Redis: `6379`
- MinIO API: `9000`
- MinIO Console: `9001`
- Kafka external listener: `9094`
- Mongo Express: `8081`

Mongo Express also supports optional basic auth env vars:

- `MONGO_EXPRESS_BASICAUTH_USERNAME` (default: `admin`)
- `MONGO_EXPRESS_BASICAUTH_PASSWORD` (default: `changeme`)

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
