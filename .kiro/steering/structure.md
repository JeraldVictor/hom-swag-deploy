# Deployment Structure

```
deploy/
├── compose.yaml          # Main Docker Compose file defining all services
├── deploy.sh             # Orchestration script (pull, up, health, safe-deploy, refresh, logs, shell)
├── build-images.sh       # Builds app images and optionally pushes them to the registry
├── .env.example          # Template for environment variables
├── .env.local            # Local development environment configuration
├── .env.prod             # Production environment configuration
├── Containerfile.*       # Dockerfiles for building images (if needed locally)
├── logs/                 # Persistent logs directory (mounted to containers)
├── docs/                 # Deployment-specific documentation and reports
├── .dockerignore         # Exclusions for Docker build context
└── .gitignore            # Exclusions for Git (including .env.* files)
```

## Service Architecture

### Infrastructure Services
- **mongodb**: Data persistence (homswag database).
- **redis**: Caching and real-time session management.
- **minio**: S3-compatible object storage for media and uploads.
- **kafka**: Event/message broker used by reporting/event workflows.

### Application Services
- **server**: The central backend API. Mounts environment variables, uploads, and logs.
- **reporting**: Separate reporting service image, connected to MongoDB, MinIO, and Kafka.
- **admin**: The administrative dashboard (served via Nginx inside the container).
- **app**: The user-facing web/mobile application.

## Key Files & Roles

- **`compose.yaml`**: Uses `${VAR:-default}` syntax to allow overrides from `.env` files. Defines the `homswag-net` network for inter-service communication.
- **`deploy.sh`**:
  - `cmd_pull`: Updates images from the configured registry.
  - `cmd_up`: Starts the stack.
  - `cmd_safe_deploy`: Orchestrates zero-downtime swaps using canary containers.
  - `cmd_health`: Validates `/health` endpoints for Server and connectivity for infra/app services.
- **`.env.*`**:
  - `SERVER_PORT`, `ADMIN_PORT`, `APP_PORT`, `REPORTING_PORT`, `KAFKA_PORT`: Define host-side port bindings.
  - `*_DATA_SOURCE`: Allows switching between named volumes and host bind-mounts.
  - `*_IMAGE_TAG`: Controls which version of the images to pull.

## Data Persistence

- **Volumes**: Named volumes (`mongodb-data`, `mongodb-config`, `redis-data`, `minio-data`, `kafka-data`) are used by default to ensure data survives container removals.
- **Mounts**: The `server` service mounts `./uploads` and `./logs` from the host for direct access and persistence.
