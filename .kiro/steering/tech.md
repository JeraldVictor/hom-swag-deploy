# Deployment Tech Stack

## Orchestration & Containers

- **Docker Compose**: Version 2.x+ (using `compose.yaml`).
- **Container Runtime**: Podman or Docker (script auto-detects).
- **Base Images**:
  - `ghcr.io/jeraldvictor/hom-swag-*` (Default application images pulled by deploy)
  - `docker.io/apache/kafka:latest` (Kafka broker; `KAFKA_IMAGE`)
  - `docker.io/nginx:1.27-alpine` (Reverse proxy)
  - `signoz/signoz-standalone:latest` (Tracing stack)
  - `otel/opentelemetry-collector-contrib:0.129.1` (OpenTelemetry collector)
  - `portainer/portainer-ce:2.30.1` (Container operations UI)
  - `docker.io/certbot/certbot:latest` (Optional certbot profile)

## Deployment Scripting

- **Bash**: 3.2+ (Compatible with macOS and Linux).
- **cURL**: For health check validations.
- **grep/sed**: For environment variable parsing and image tag resolution.
- **Nginx**: Used by frontend containers and deployment templates for serving Admin/App/Partner traffic through proxy routing.

## Networking & Security

- **Docker Bridge Network**: `homswag-net` for internal service-to-service communication.
- **Port Mapping**:
  - `3000`: Server/API, reporting, and app listeners (host mappings controlled by `*_PORT` vars)
  - `80`: Admin dashboard and Partner app frontend entrypoints
  - `8080`: Signoz UI when enabled by `SIGNOZ_HTTP_PORT`
  - `9094`: Kafka external listener (optional)
  - `8000/9443`: Portainer UI
  - `14318`: OTEL collector HTTP
  - `13133`: OTEL collector health
- **JWT**: Token-based authentication for Server and BFF.
- **Kafka**: Internal broker advertised as `kafka:9092`; external local access defaults to `127.0.0.1:9094`.
- **SSL/TLS**: Terminated at Nginx/public proxy or via certificate tooling.
- **Frontend Runtime Config**: Nginx templates live in `nginx/templates/`; build-time `VITE_*` values still require rebuilding images.

## Infrastructure Versions

- **Kafka**: Apache Kafka latest image (overridable with `KAFKA_SOURCE_IMAGE`/`KAFKA_IMAGE`)
- **Nginx**: `docker.io/nginx:1.27-alpine`
- **Signoz**: `signoz/signoz-standalone:latest`
- **OpenTelemetry**: `otel/opentelemetry-collector-contrib:0.129.1`
- **Portainer**: `portainer/portainer-ce:2.30.1`

## Environment Variables

The deployment relies on a specific set of environment variables defined in `.env.local` or `.env.prod`. These are injected into:
1.  **Compose Engine**: To configure ports, volumes, and image tags.
2.  **Server Container**: To configure the backend runtime (DB URIs, secrets, feature flags).
3.  **App Container**: For server-side rendering configurations.

*Note: `VITE_*` variables are baked into Admin, App, and Partner images at build time and cannot be changed via the deployment script without rebuilding the images.*
