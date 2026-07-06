# Deployment Structure

```
deploy/
├── compose.yaml          # Main Docker Compose file defining all services
├── deploy.sh             # Orchestration script (pull, up, health, safe-deploy, refresh, logs, shell)
├── build-images.sh       # Builds app images and optionally pushes them to the registry
├── README.md             # Operator-facing deployment notes
├── .env.example          # Template for environment variables
├── .env.local            # Local development environment configuration
├── .env.prod             # Production environment configuration
├── Containerfile.*       # Dockerfiles for building images (if needed locally)
├── nginx/                # Runtime Nginx templates and entrypoint helpers
├── .build-context/       # Generated build context assets for container builds
├── logs/                 # Persistent logs directory (mounted to containers)
├── docs/                 # Deployment-specific documentation and reports
├── .dockerignore         # Exclusions for Docker build context
└── .gitignore            # Exclusions for Git (including .env.* files)
```

## Service Architecture

### Infrastructure Services
- **kafka**: Event/message broker used by reporting/event workflows.
- **otel-collector**: OpenTelemetry collector for signal forwarding.
- **signoz**: Tracing/metrics storage and UI.
- **portainer**: Operational dashboard for container management.
- **nginx**: Public TLS/router entrypoint for HTTP(S) traffic.
- **signoz-retention**: Retention helper for Signoz clickhouse data.
- **certbot**: Optional certificate automation profile.

### Application Services
- **server**: Central backend API. Mounts environment variables, uploads, and logs.
- **reporting**: Separate reporting service image, connected to Kafka and MinIO-compatible object storage.
- **admin**: The administrative dashboard (served via Nginx inside the container).
- **app**: The user-facing web/mobile application.
- **partner**: Mobile/web partner field-app dashboard.

## Key Files & Roles

- **`compose.yaml`**: Uses `${VAR:-default}` syntax to allow overrides from `.env` files. Defines the `homswag-net` network for inter-service communication.
- **`deploy.sh`**:
  - `cmd_pull`: Updates images from the configured registry.
  - `cmd_up`: Starts the stack.
  - `cmd_safe_deploy`: Orchestrates zero-downtime swaps using canary containers.
  - `cmd_health`: Validates `/health` endpoints for Server and connectivity for infra/app services.
- **`.env.*`**:
  - `SERVER_PORT`, `ADMIN_PORT`, `APP_PORT`, `PARTNER_PORT`, `REPORTING_PORT`, `KAFKA_PORT`: Define host-side port bindings.
  - `*_DATA_SOURCE`: Allows switching between named volumes and host bind-mounts.
  - `*_IMAGE_TAG`: Controls which version of the images to pull.
  - `IMAGE_REGISTRY`, `PUSH_REGISTRY`: Control registry namespace for image pulls/pushes.

## Data Persistence

- **Volumes**: Named volumes (`kafka-data`, `nginx-cache`, `reporting-temp`, `portainer_data`, `signoz_data`, `signoz_clickhouse_data`) are used by default to preserve runtime state.
- **Mounts**: The `server` service mounts `./uploads` and `./logs` from the host for direct access and persistence.
