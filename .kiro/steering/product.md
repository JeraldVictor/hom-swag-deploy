# Deployment Overview

The `deploy` workspace provides a unified environment for running the entire HomSwag platform using Docker/Podman Compose. It manages the lifecycle of infrastructure services (MongoDB, Redis, MinIO, Kafka) and application services (Server, Reporting, Admin, App).

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

- **Image-Based**: Services are deployed using pre-built images pulled from GHCR (GitHub Container Registry). This ensures consistency between environments and avoids build-time issues on the deployment host.
- **Zero-Downtime (Prod)**: The `prod` profile uses a "canary" strategy where new containers are started and health-checked on temporary ports before swapping with the live containers.
- **Infrastructure**: Shared MongoDB, Redis, MinIO, and Kafka instances managed as part of the compose stack.
- **Reverse Proxy**: Typically sits in front of the stack (e.g., Nginx) to handle TLS and routing to the specific ports (`3000`, `3001`, `3002`, and reporting on `3003` when exposed).

## Target Environments

- **Local**: For testing the full stack locally with dummy credentials and simplified networking.
- **Production**: For deploying to the live environment with strict authentication, secure secrets, and health monitoring.
