# HomSwag Deploy

Deployment workspace for running the full HomSwag stack with Podman/Docker Compose.

## What this folder does

- Uses app sources from `repos/` when present, or from the sibling workspace folders
- Builds images for `server`, `reporting`, `admin`, `app`, and `kafka`
- Pulls/deploys production application images from GitHub Container Registry
- Pushes release images to `ghcr.io/jeraldvictor` only when requested
- Starts Kafka, nginx, and application containers in production
- Uses externally managed MongoDB/DocumentDB, Valkey/Redis-protocol cache, and object storage
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

## Registry Login

Production deploys pull HomSwag images from GitHub Container Registry.
If the packages are private, log in on the deployment host before running
`deploy`, `pull`, or `clean`:

```bash
echo "<github-token>" | docker login ghcr.io -u "<github-user>" --password-stdin
```

The GitHub token needs package read access for deploys and package write access
for `build-images.sh --push`.

---

## Environment profiles

Use one of these files:

- `.env.local` → local/dev values
- `.env.prod` → production values

The script accepts profile selection with:

- `--env local`
- `--env prod`

If no profile is passed, deploy and build commands default to `prod`.
Local work must be explicit with `--env local`.

`compose.yaml` is the production base file. Local infrastructure and localhost
port bindings live in `compose.local.yaml`, which `deploy.sh` uses only for the
`local` profile.

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

### Quick command reference

All commands below are run from the `deploy/` folder.

Production is the default profile. Local commands must always pass
`--env local` so localhost images and ports are never used accidentally for
production.

#### Local build and deploy

Use this flow for local testing with local images and direct localhost ports:

```bash
# Build all local deployment images. Does not push.
./build-images.sh --env local

# Build only selected local images after frontend/backend changes.
./build-images.sh --env local admin app
./build-images.sh --env local server

# Start or update the local stack from local images.
./deploy.sh --env local deploy

# Validate the local stack.
./deploy.sh --env local health
./deploy.sh --env local status
```

Local URLs:

```bash
http://localhost:3000/health           # API server
http://localhost:5173                  # admin
http://localhost:8080                  # customer app
http://localhost:3003/health           # reporting service
mongodb://admin:dummypass@localhost:27018/homswag?authSource=admin
http://localhost:9101                  # MinIO console
```

Local container data is bind-mounted under `deploy/volume-data/` and ignored by
git. This includes MongoDB, Redis, MinIO, Kafka, nginx cache, server uploads,
and server logs. `./deploy.sh --env local down` keeps that data; remove
`deploy/volume-data/` only when you want a fully clean local state.

Useful local operations:

```bash
./deploy.sh --env local logs           # follow all logs
./deploy.sh --env local logs server    # follow one service
./deploy.sh --env local restart app    # restart one service
./deploy.sh --env local recreate app   # recreate one service
./deploy.sh --env local down           # stop/remove containers, keep volumes
```

Run commands inside local containers:

```bash
./deploy.sh --env local shell server
./deploy.sh --env local exec server -- node -v
./deploy.sh --env local exec server -- pnpm --version
./deploy.sh --env local exec server -- pnpm seed:prod -- --upsert
./deploy.sh --env local exec server -- pnpm seed:prod -- --upsert --only=locations,offices,menu,products
./deploy.sh --env local seed --upsert --only=locations,offices,menu,products
./deploy.sh --env local seed-reports
```

`server` is the right service for seeds and most `pnpm` commands. The `admin`
runtime container is nginx-only, and the customer `app` runtime container runs
the built Nitro output, so those containers are useful for shell inspection but
not for source-level pnpm workflows.

Local safety rules:

- Local builds use `.env.local`, `compose.local.yaml`, and `homswag-local/*`
  image names.
- Local deploys skip registry pulls by default through `PULL_IMAGES=false`.
- `./build-images.sh --env local --push` is intentionally blocked.
- Local nginx is internal-only and does not publish HTTP or HTTPS ports.

#### Production build and deploy

Production build and deploy uses `.env.prod` and registry images. Use this flow
when publishing release images and deploying PROD:

```bash
# Build production images locally, without pushing.
./build-images.sh --env prod

# Build and push production images to the registry.
./build-images.sh --env prod --push

# Clean rebuild and push production images.
./build-images.sh --env prod --no-cache --push

# Build/push selected production services.
./build-images.sh --env prod server reporting --push
./build-images.sh --env prod admin app --push

# Graceful production deploy. This is also the default if --env is omitted.
./deploy.sh --env prod deploy

# Validate production public routes.
./deploy.sh --env prod health
```

Useful production operations:

```bash
./deploy.sh --env prod pull            # pull registry images only
./deploy.sh --env prod status          # show running containers
./deploy.sh --env prod logs server     # follow server logs
./deploy.sh --env prod restart nginx   # restart nginx
./deploy.sh --env prod certs           # issue/renew Let's Encrypt certs
```

Run commands inside production containers:

```bash
./deploy.sh --env prod shell server
./deploy.sh --env prod exec server -- node -v
./deploy.sh --env prod exec server -- pnpm seed:prod -- --upsert --only=reports
./deploy.sh --env prod seed-reports
```

Be careful with production seeds. Prefer scoped, idempotent/upsert commands
such as `--upsert --only=reports` unless you intentionally need a broader seed.

Production safety rules:

- Build/deploy defaults to `prod` when no `--env` is provided.
- Production frontend builds fail if required URLs are missing or point to
  `localhost`, `127.0.0.1`, or `0.0.0.0`.
- Push is allowed only for production profile with `.env.prod`.
- Prefer `./deploy.sh --env prod deploy` for normal PROD rollout; it performs
  the graceful scale-up, health validation, and old-container removal flow.

### Build and push release images

Build images locally:

```bash
./build-images.sh --env prod
```

Build and push to GitHub Container Registry:

```bash
./build-images.sh --env prod --push
```

Clean rebuild and push production images:

```bash
./build-images.sh --env prod --no-cache --push
```

Build selected services:

```bash
./build-images.sh --env prod server reporting --push
./build-images.sh --env prod --tag 2026.06.15 --push
```

The build script defaults to these registries:

```bash
IMAGE_REGISTRY=ghcr.io/jeraldvictor
PUSH_REGISTRY=ghcr.io/jeraldvictor
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

Before building, `build-images.sh` logs the resolved build environment,
including the frontend URLs baked into the `admin` and `app` images. For
production builds, the script refuses to continue if a required frontend URL is
missing or points to `localhost`, `127.0.0.1`, or `0.0.0.0`.

For production deploys, `.env.prod` sets:

```bash
IMAGE_REGISTRY=ghcr.io/jeraldvictor
PUSH_REGISTRY=ghcr.io/jeraldvictor
SERVER_IMAGE=ghcr.io/jeraldvictor/hom-swag-server:latest
REPORTING_IMAGE=ghcr.io/jeraldvictor/hom-swag-reporting:latest
ADMIN_IMAGE=ghcr.io/jeraldvictor/hom-swag-admin:latest
APP_IMAGE=ghcr.io/jeraldvictor/hom-swag-app:latest
KAFKA_IMAGE=ghcr.io/jeraldvictor/hom-swag-kafka:latest
```

### Deploy existing images

```bash
./deploy.sh [--env local|prod] \
            [deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|exec|status|health|seed|seed-reports]
```

### Full deploy

Global flags may be placed before *or* after the command name; the script
will ignore them when determining which services to act on.

```bash
./deploy.sh --env local deploy
./deploy.sh --env prod deploy
```

Production deploy is graceful: it pulls images, scales app services up behind
nginx, verifies the new-image containers directly from the nginx network,
verifies the public SSL routes, removes old-image containers one service at a
time, and settles back to the configured replica counts.

```bash
SERVER_REPLICAS=1
REPORTING_REPLICAS=1
ADMIN_REPLICAS=1
APP_REPLICAS=1
DEPLOY_REPLICAS=2
```

`DEPLOY_REPLICAS` is treated as a minimum total during the temporary scale-up.
If a service normally runs more than one replica, the deploy script scales to at
least double the normal replica count so it can prove the replacement set is
healthy before removing the old containers.

Local deploy uses `compose.local.yaml` with `.env.local`, which starts MongoDB,
Redis, MinIO, Kafka, nginx, and the app services together. Browser-facing local
traffic uses direct localhost ports only; service-to-service calls inside Docker
still use compose service names such as `server` and `reporting`.

```bash
http://localhost:3000/health           # API server
http://localhost:5173                  # admin
http://localhost:8080                  # customer app
http://localhost:3003/health           # reporting service
http://localhost:9101                  # MinIO console
```

Local nginx is kept internal to the compose stack and does not publish HTTPS
ports. Image pulls and image pruning are skipped by default for local deploys;
build local frontend images first when changing `admin` or `app`.

### Clean deploy

Clean deploy removes the compose stack first, pulls fresh images, starts from
scratch, validates health, then prunes old images. This is intentionally
disruptive; use `./deploy.sh --env prod deploy` for the graceful production
path.

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
./build-images.sh --env local           # add --no-cache to force a clean build
./deploy.sh --env local deploy
```

Registry pushes are intentionally production-only. `build-images.sh --push`
refuses non-prod profiles and refuses any env file other than `.env.prod`.

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

For production application releases, prefer:

```bash
./deploy.sh --env prod deploy
```

`clean`, `down`, `recreate`, and `refresh` stop or force-recreate containers and
can cause downtime for public app services. Use them for maintenance windows,
infrastructure-only changes, or targeted recovery.

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
