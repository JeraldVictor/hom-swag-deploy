# HomSwag Deploy

Deployment workspace for running the full HomSwag stack with Podman/Docker Compose.

## What this folder does

- Uses app sources from `repos/` when present, or from the sibling workspace folders
- Builds images for `server`, `reporting`, `admin`, `app`, and `kafka`
- Pulls/deploys production application images from DigitalOcean Container Registry
- Pushes release images to `registry.digitalocean.com/homswag-repo` only when requested
- Starts Kafka, nginx, and application containers in production
- Uses externally managed MongoDB/DocumentDB, Valkey/Redis-protocol cache, and object storage
- Serves public traffic through the compose-managed `nginx` container with SSL
- Supports environment profiles (`local`, `prod`)
- Supports deploying only selected services

---

## Prerequisites

- `podman` (preferred) or `docker`
- `doctl` on production hosts that pull from DigitalOcean Container Registry
- `git`
- Access to these repositories:
  - `REPO_SERVER`
  - `REPO_REPORTING`
  - `REPO_ADMIN`
  - `REPO_APP`

---

## Registry Login

Production deploys pull HomSwag images from DigitalOcean Container Registry.
Log in on the deployment host before running `deploy`, `pull`, or `clean`:

```bash
doctl auth init
doctl registry login
```

If Docker is already logged in to `registry.digitalocean.com`, the deploy script
will use those credentials. Set `DOCR_SKIP_LOGIN=true` to skip the automatic
`doctl registry login` refresh.

---

## Environment profiles

Use one of these files:

- `.env.local` → local/dev values
- `.env.prod` → production values

The script accepts profile selection with:

- `--env local`
- `--env prod`

If no profile is passed, it defaults to `local`.

### External data services

Production uses managed services for MongoDB/DocumentDB, Redis, and object
storage through `.env.prod`:

- `MONGODB_URI`
- `VALKEY_HOST` or `REDIS_HOST`
- `VALKEY_PORT` or `REDIS_PORT`
- `VALKEY_USERNAME` or `REDIS_USERNAME` when your Valkey credentials include a username
- `VALKEY_PASSWORD` or `REDIS_PASSWORD`
- `VALKEY_TLS` or `REDIS_TLS`
- `MINIO_ENDPOINT`
- `MINIO_PORT`
- `MINIO_ACCESS_KEY`
- `MINIO_SECRET_KEY`
- `MINIO_USE_SSL`
- `KAFKA_BOOTSTRAP_SERVERS`

The deploy health command validates those external services through the server
`/health` endpoint. This deploy stack does not run local MongoDB, Valkey/Redis,
MinIO, or Mongo Express containers.

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

If a cert is missing, `deploy.sh` creates a temporary 7-day self-signed cert so
nginx can start. To issue trusted Let's Encrypt certificates, make sure DNS for
all four domains points to the deployment host and port `80` is reachable, then
run:

```bash
./deploy.sh --env prod recreate nginx
./deploy.sh --env prod certs
```

The command uses the nginx HTTP-01 challenge path, installs the issued
certificates into `NGINX_CERTS_PATH`, verifies they are not self-signed, and
reloads nginx.

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
BUILD_PLATFORM=linux/amd64
KAFKA_IMAGE_TAG=latest
KAFKA_SOURCE_IMAGE=apache/kafka:latest
KAFKA_PLATFORM=linux/amd64
```

Override the build/deploy pull source with `IMAGE_REGISTRY`.
Override the push target with `PUSH_REGISTRY` or `./build-images.sh --push-registry ...`.
All image builds default to `linux/amd64`; override with `BUILD_PLATFORM` or
`./build-images.sh --platform ...`.
Kafka is pulled from `KAFKA_SOURCE_IMAGE`, then tagged as
`IMAGE_REGISTRY/hom-swag-kafka:KAFKA_IMAGE_TAG`. `KAFKA_PLATFORM` controls
which platform variant is repacked and pushed.

For production deploys, `.env.prod` sets:

```bash
IMAGE_REGISTRY=registry.digitalocean.com/homswag-repo
PUSH_REGISTRY=registry.digitalocean.com/homswag-repo
SERVER_IMAGE=registry.digitalocean.com/homswag-repo/hom-swag-server:latest
REPORTING_IMAGE=registry.digitalocean.com/homswag-repo/hom-swag-reporting:latest
ADMIN_IMAGE=registry.digitalocean.com/homswag-repo/hom-swag-admin:latest
APP_IMAGE=registry.digitalocean.com/homswag-repo/hom-swag-app:latest
KAFKA_IMAGE=registry.digitalocean.com/homswag-repo/hom-swag-kafka:latest
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
  - `VALKEY_PASSWORD`
  - `MINIO_SECRET_KEY`
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
- Kafka external listener: `9094`

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
