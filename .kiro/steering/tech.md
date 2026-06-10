# Deployment Tech Stack

## Orchestration & Containers

- **Docker Compose**: Version 2.x+ (using `compose.yaml`).
- **Container Runtime**: Podman or Docker (script auto-detects).
- **Base Images**:
  - `mongo:8` (Infrastructure)
  - `redis:7-alpine` (Infrastructure)
  - `minio/minio:latest` (Infrastructure)
  - `apache/kafka:latest` (Infrastructure)
  - `ghcr.io/jeraldvictor/hom-swag-*` (Application images)

## Deployment Scripting

- **Bash**: 3.2+ (Compatible with macOS and Linux).
- **cURL**: For health check validations.
- **grep/sed**: For environment variable parsing and image tag resolution.

## Networking & Security

- **Docker Bridge Network**: `homswag-net` for internal service-to-service communication.
- **Port Mapping**:
  - `3000`: Server API
  - `3001`: Admin Dashboard
  - `3002`: User App
  - `3003`: Reporting service
  - `27017`: MongoDB (optional)
  - `9094`: Kafka external listener (optional)
  - `9000/9001`: MinIO API/Console
- **JWT**: Token-based authentication for Server and BFF.
- **Kafka**: Internal broker advertised as `kafka:9092`; external local access defaults to `127.0.0.1:9094`.
- **SSL/TLS**: Handled externally (e.g., Nginx reverse proxy) or via `MINIO_USE_SSL`.

## Infrastructure Versions

- **MongoDB**: 8.0
- **Redis**: 7.x
- **MinIO**: S3 API Compatible
- **Kafka**: Apache Kafka latest image

## Environment Variables

The deployment relies on a specific set of environment variables defined in `.env.local` or `.env.prod`. These are injected into:
1.  **Compose Engine**: To configure ports, volumes, and image tags.
2.  **Server Container**: To configure the backend runtime (DB URIs, secrets, feature flags).
3.  **App Container**: For server-side rendering configurations.

*Note: VITE_* variables are baked into Admin and App images at build time and cannot be changed via the deployment script without rebuilding the images.*
