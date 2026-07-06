# Deployment Overview

The `deploy` workspace provides a unified environment for running the HomSwag platform using Docker/Podman Compose. It manages the lifecycle of runtime application services (Server, Reporting, Admin, App, Partner) and platform services (Kafka, observability, and reverse proxy tooling).

## Key Components

- **Docker Compose (`compose.yaml`)**: The source of truth for the containerized architecture. It defines networks, volumes, and service configurations.
- **Deployment Script (`deploy.sh`)**: A sophisticated Bash script that orchestrates the deployment process. It supports:
  - Multi-environment profiles (`local`, `prod`).
  - Zero-downtime "safe" deployments for production (using canary containers).
  - Health validation across all services.
  - Container management (logs, shell, status, restart, recreate).
  - Database seeding within containers.
  - Image refresh, log dumps, interactive shells, status, health, clean, down, and prune commands.
- **Environment Management**: Profile-specific configuration using `.env.local` and `.env.prod`.

## Deployment Strategy

- **Image-Based**: Services are deployed using pre-built images pulled from configured registries (default: `ghcr.io/jeraldvictor/...`). Builds can be pushed with `build-images.sh --push` to the configured `PUSH_REGISTRY`.
- **Zero-Downtime (Prod)**: The `prod` profile uses a "canary" strategy where new containers are started and health-checked on temporary ports before swapping with the live containers.
- **Infrastructure**: Messaging and observability services (Kafka, OpenTelemetry, Signoz, Portainer, Nginx) are part of the compose stack, while persistent platforms (MongoDB/Redis/MinIO/Object storage) are typically externalized through environment variables.
- **Reverse Proxy**: Nginx routes traffic to server/admin/app/partner/reporting surfaces and hosts monitoring endpoints.

## Target Environments

- **Local**: For testing the full stack locally with dummy credentials and simplified networking.
- **Production**: For deploying to the live environment with strict authentication, secure secrets, and health monitoring.
