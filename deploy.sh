#!/usr/bin/env bash
# =============================================================================
# HomSwag — Deploy script (image-based — no git pull, no local build)
#
# Usage:
#   ./deploy.sh                      # production deploy: pull images from registry + start all services
#   ./deploy.sh prod                 # use .env.prod and deploy (shorthand for --env prod)
#   ./deploy.sh --env prod           # same as above (explicit flag form)
#   ./deploy.sh prod logs [svc...]   # any sub-command can be prefixed with prod|local
#   ./deploy.sh pull                 # pull latest images only
#   ./deploy.sh up                   # start services (skip image pull)
#   ./deploy.sh restart [svc...]     # restart one or all containers
#   ./deploy.sh recreate [svc...]    # force-recreate one or all containers
#   ./deploy.sh refresh [svc...]     # pull + force-recreate one or all containers
#   ./deploy.sh clean                # remove stack, pull fresh images, start, verify health, prune
#   ./deploy.sh down                 # stop and remove containers (volumes kept)
#   ./deploy.sh prune                # docker system prune -a --volumes (full cleanup)
#   ./deploy.sh logs [svc...]        # follow logs, last 100 lines
#   ./deploy.sh dump <svc>           # print last 100 lines (no follow)
#   ./deploy.sh logs-all <svc>       # print ALL logs for a service
#   ./deploy.sh shell <svc>          # open interactive terminal in container
#   ./deploy.sh exec <svc> -- <cmd>  # run a one-off command in container
#   ./deploy.sh status               # show running containers
#   ./deploy.sh health               # validate service HTTP endpoints
#   ./deploy.sh memory [svc] [opts]  # collect host/container memory evidence
#   ./deploy.sh valkey status        # inspect managed Valkey memory and key namespaces
#   ./deploy.sh cleanup [opts]       # preview/apply aged log and temp cleanup
#   ./deploy.sh help                 # show commands without requiring Docker or an env file
#   ./deploy.sh certs                # show Caddy-managed TLS certificate status
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] \u2714${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] \u26a0${NC}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] \u2718${NC}  $*" >&2; exit 1; }

is_truthy() {
    case "${1:-}" in
        true|1|yes|on|y|TRUE|YES|ON|Y) return 0 ;;
        *) return 1 ;;
    esac
}

print_help() {
    cat <<EOF
Usage: $0 [--env local|prod] <command> [arguments]

Profiles:
  --env prod   Use .env.prod (default)
  --env local  Use .env.local and compose.local.yaml

Deployment:
  deploy       Pull images and perform a health-checked deployment (default)
  pull         Pull configured images only
  up           Start services without pulling
  restart      Restart services             (e.g. ./deploy.sh restart server)
  recreate     Force-recreate services       (e.g. ./deploy.sh recreate server)
  refresh      Pull and force-recreate       (e.g. ./deploy.sh refresh server)
  clean        Rebuild the stack, verify health, and prune old images
  down         Stop/remove containers while preserving volumes

Operations:
  status       Show containers
  health       Validate service endpoints
  logs         Follow the last 100 log lines  (e.g. ./deploy.sh logs server)
  dump         Print the last 100 log lines   (e.g. ./deploy.sh dump server)
  logs-all     Print all available logs       (e.g. ./deploy.sh logs-all server)
  memory       Capture VPS/container memory evidence
               Example: ./deploy.sh memory server --samples 60 --interval 10
  valkey       Inspect or safely trim managed Valkey cache data
               Example: ./deploy.sh valkey status
               Example: ./deploy.sh valkey guard --threshold 60 --apply
  cleanup      Preview/apply aged logs and temporary-data cleanup
               Example: ./deploy.sh cleanup --apply
  prune        Interactively remove all unused Docker resources, including volumes
  certs        Validate Caddy TLS certificate configuration/status

Container/application:
  shell         Open a container shell         (e.g. ./deploy.sh shell server)
  exec          Execute a container command    (e.g. ./deploy.sh exec server -- node -v)
  seed          Run the server database seed
  seed-reports  Upsert report definitions only

Help:
  help, -h, --help

See OPERATIONS.md for memory collection, cleanup retention, and scheduling.
EOF
}

# ── Parse global flags ─────────────────────────────────────────────────────────
ENV_PROFILE="${DEPLOY_ENV:-prod}"
COMMAND=""
REMAINING_ARGS=()
UNKNOWN_ARGS=()

is_command() {
    case "$1" in
        deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|exec|status|health|memory|valkey|cleanup|certs|seed|seed-reports|help)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
    arg="${ARGS[$i]}"
    case "$arg" in
        -e|--env)
            next_index=$((i + 1))
            [[ "$next_index" -lt "${#ARGS[@]}" ]] || die "Missing value for --env (expected: local|prod)"
            ENV_PROFILE="${ARGS[$next_index]}"
            i=$next_index
            ;;
        prod|production|local)
            if [[ -z "$COMMAND" ]]; then
                ENV_PROFILE="$arg"
            else
                REMAINING_ARGS+=("$arg")
            fi
            ;;
        -h|--help)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="help"
            else
                REMAINING_ARGS+=("$arg")
            fi
            ;;
        *)
            if [[ -z "$COMMAND" ]] && is_command "$arg"; then
                COMMAND="$arg"
            elif [[ -z "$COMMAND" ]]; then
                UNKNOWN_ARGS+=("$arg")
            else
                REMAINING_ARGS+=("$arg")
            fi
            ;;
    esac
done

if [[ "${#UNKNOWN_ARGS[@]}" -gt 0 && -z "$COMMAND" ]]; then
    die "Unknown command '${UNKNOWN_ARGS[0]}'. Use: ${0} [--env local|prod] {deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|exec|status|health|memory|valkey|cleanup|certs|seed|seed-reports}"
fi

if [[ -z "$COMMAND" ]]; then
    COMMAND="deploy"
fi

# Help must work on a fresh host before env files, Docker, or Podman are configured.
if [[ "$COMMAND" == "help" ]]; then
    print_help
    exit 0
fi

if [[ "${#REMAINING_ARGS[@]}" -gt 0 ]]; then
    set -- "${REMAINING_ARGS[@]}"
else
    set --
fi

case "$ENV_PROFILE" in
    local)           ENV_FILE=".env.local" ;;
    prod|production) ENV_FILE=".env.prod"  ;;
    *)               die "Invalid env profile '$ENV_PROFILE'. Use: local | prod" ;;
esac

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Create it before deploying."

# Export so compose.yaml can resolve ${DEPLOY_ENV_FILE} for env_file directives.
export DEPLOY_ENV_FILE="$ENV_FILE"

# Source the env file so shell variables (ports etc.) are available here too.
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        line="${line%%  #*}"; line="${line%% #*}"
        export "$line"
    fi
done < "$ENV_FILE"

AUTO_SEED_REPORT_DEFINITIONS="${AUTO_SEED_REPORT_DEFINITIONS:-true}"
PROXY_STACK="${PROXY_STACK:-caddy}"
case "$PROXY_STACK" in
    caddy|nginx) ;;
    *) die "Invalid PROXY_STACK='$PROXY_STACK'. Use: caddy | nginx" ;;
esac
PROXY_SERVICE="$PROXY_STACK"
OBSERVABILITY_STACK="${OBSERVABILITY_STACK:-false}"

# ── Discover compose binary ────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    if docker info >/tmp/homswag-docker-info.log 2>&1; then
        COMPOSE_BIN="docker compose"
    else
        if grep -qiE "permission denied|cannot connect|connection to the Docker daemon" /tmp/homswag-docker-info.log; then
            warn "Docker CLI is installed but the Docker daemon/socket is not reachable."
            if command -v podman &>/dev/null; then
                warn "Falling back to podman compose."
                COMPOSE_BIN="podman compose"
            else
                die "Start Docker Desktop (or make sure your Docker daemon is running) and retry."
            fi
        else
            die "Docker is installed but not usable: $(tr '\n' ' ' < /tmp/homswag-docker-info.log | head -c 200)"
        fi
    fi
elif command -v podman &>/dev/null; then
    warn "docker not found — falling back to podman compose"
    COMPOSE_BIN="podman compose"
else
    die "Neither docker nor podman found. Please install one of them."
fi

COMPOSE_FILES="-f compose.yaml"
if [[ "$PROXY_STACK" == "nginx" ]]; then
    [[ -f "compose.nginx.yaml" ]] || die "compose.nginx.yaml not found. nginx fallback requires the nginx overlay."
    COMPOSE_FILES="$COMPOSE_FILES -f compose.nginx.yaml"
fi
if [[ "$ENV_PROFILE" == "local" ]]; then
    [[ -f "compose.local.yaml" ]] || die "compose.local.yaml not found. Local deploy requires the local compose override."
    COMPOSE_FILES="$COMPOSE_FILES -f compose.local.yaml"
fi

COMPOSE_PROFILES_ARGS="--profile $PROXY_STACK"
if is_truthy "$OBSERVABILITY_STACK"; then
    COMPOSE_PROFILES_ARGS="$COMPOSE_PROFILES_ARGS --profile observability"
fi
COMPOSE="$COMPOSE_BIN $COMPOSE_PROFILES_ARGS --env-file $ENV_FILE $COMPOSE_FILES"

# ── Port defaults (overridden by env file if set) ──────────────────────────────
SERVER_PORT="${SERVER_PORT:-3000}"
ADMIN_PORT="${ADMIN_PORT:-3001}"
APP_PORT="${APP_PORT:-3002}"
PARTNER_PORT="${PARTNER_PORT:-3004}"
REPORTING_PORT="${REPORTING_PORT:-3003}"
CADDY_HTTP_PORT="${CADDY_HTTP_PORT:-${NGINX_HTTP_PORT:-80}}"
CADDY_HTTPS_PORT="${CADDY_HTTPS_PORT:-${NGINX_HTTPS_PORT:-443}}"
PROXY_HTTPS_PORT="$CADDY_HTTPS_PORT"
if [[ "$PROXY_STACK" == "nginx" ]]; then
    PROXY_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
fi
LOCAL_HEALTH_HOST="${HOST_BIND_ADDRESS:-127.0.0.1}"
if [[ "$LOCAL_HEALTH_HOST" == "0.0.0.0" ]]; then
    LOCAL_HEALTH_HOST="127.0.0.1"
fi
APP_DOMAIN="${APP_DOMAIN:-www.homswag.com}"
APEX_APP_DOMAIN="${APEX_APP_DOMAIN:-homswag.com}"
WWW_APP_DOMAIN="${WWW_APP_DOMAIN:-$APP_DOMAIN}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.homswag.com}"
API_DOMAIN="${API_DOMAIN:-api.alpha.homswag.com}"
REPORTING_DOMAIN="${REPORTING_DOMAIN:-reporting.alpha.homswag.com}"
PARTNER_DOMAIN="${PARTNER_DOMAIN:-partner.homswag.com}"
SIGNOZ_DOMAIN="${SIGNOZ_DOMAIN:-signoz.homswag.com}"
PORTAINER_DOMAIN="${PORTAINER_DOMAIN:-ports.homswag.com}"
MONITOR_DOMAIN="${MONITOR_DOMAIN:-monitor.homswag.com}"
SERVER_REPLICAS="${SERVER_REPLICAS:-1}"
REPORTING_REPLICAS="${REPORTING_REPLICAS:-1}"
ADMIN_REPLICAS="${ADMIN_REPLICAS:-1}"
APP_REPLICAS="${APP_REPLICAS:-1}"
PARTNER_REPLICAS="${PARTNER_REPLICAS:-1}"
DEPLOY_REPLICAS="${DEPLOY_REPLICAS:-2}"

observability_enabled() {
    is_truthy "$OBSERVABILITY_STACK"
}

# =============================================================================
# Sub-commands
# =============================================================================

is_ghcr_registry() {
    [[ "${IMAGE_REGISTRY:-}" == ghcr.io/* ]]
}

ensure_registry_auth() {
    if ! is_ghcr_registry; then
        return
    fi

    warn "GHCR pulls require Docker to be logged in to ghcr.io if packages are private"
    warn "Use: echo '<github-token>' | docker login ghcr.io -u '<github-user>' --password-stdin"
}

ensure_host_mount_dir() {
    local label="$1"
    local path="${2:-}"

    [[ -n "$path" ]] || return 0
    case "$path" in
        /*|./*|../*) ;;
        *) return 0 ;;
    esac

    mkdir -p "$path" || die "Failed to create ${label} directory: ${path}"
}

ensure_persistent_mounts() {
    ensure_host_mount_dir "Caddy data" "${CADDY_DATA_SOURCE:-}"
    ensure_host_mount_dir "Caddy config" "${CADDY_CONFIG_SOURCE:-}"
    ensure_host_mount_dir "Server uploads" "${UPLOAD_SOURCE:-./uploads}"
    ensure_host_mount_dir "Server logs" "${LOG_PATH:-./logs}"
    ensure_host_mount_dir "Server diagnostics" "${DIAGNOSTICS_SOURCE:-./diagnostics}"
    ensure_host_mount_dir "Memory reports" "${MEMORY_REPORTS_PATH:-./memory-diagnostics}"
    if observability_enabled; then
        ensure_host_mount_dir "Portainer data" "${PORTAINER_DATA_SOURCE:-}"
        ensure_host_mount_dir "SigNoz data" "${SIGNOZ_DATA_SOURCE:-}"
        ensure_host_mount_dir "SigNoz ClickHouse data" "${SIGNOZ_CLICKHOUSE_DATA_SOURCE:-}"
    fi
}

cmd_certs() {
    echo ""
    if [[ "$PROXY_STACK" == "nginx" ]]; then
        echo -e "${BOLD}━━━  nginx TLS certificate status  ━━━${NC}"
        warn "nginx fallback expects certificates in NGINX_CERTS_PATH=${NGINX_CERTS_PATH:-./nginx/certs}."
        warn "Use the existing nginx/certs layout before switching production traffic to nginx."
        return
    fi

    echo -e "${BOLD}━━━  Caddy TLS certificate status  ━━━${NC}"
    log "Caddy obtains and renews public TLS certificates automatically when DNS points at this host and ports 80/443 are reachable."
    $COMPOSE up -d "$PROXY_SERVICE"
    reload_proxy
    $COMPOSE exec -T "$PROXY_SERVICE" caddy validate --config /etc/caddy/Caddyfile >/dev/null
    ok "Caddy config is valid and loaded."
    log "Run './deploy.sh --env ${ENV_PROFILE} health' to verify live HTTPS routes."
    log "Run './deploy.sh --env ${ENV_PROFILE} logs caddy' to inspect ACME issuance/renewal details."
}

cmd_pull() {
    echo ""
    echo -e "${BOLD}━━━  Pulling images from registry  ━━━${NC}"
    log "Using env file: $ENV_FILE"
    if [[ "${PULL_IMAGES:-true}" != "true" ]]; then
        warn "Skipping image pull because PULL_IMAGES=${PULL_IMAGES:-false}"
        return
    fi
    ensure_registry_auth
    if ! $COMPOSE pull; then
        if is_ghcr_registry; then
            die "Could not pull from $IMAGE_REGISTRY. Log in on this host with 'docker login ghcr.io', then retry."
        fi
        die "Image pull failed."
    fi
    ok "All images up-to-date"
}

cmd_up() {
    echo ""
    echo -e "${BOLD}━━━  Starting services  ━━━${NC}"
    ensure_persistent_mounts
    $COMPOSE up -d --remove-orphans \
        --scale server="$SERVER_REPLICAS" \
        --scale reporting="$REPORTING_REPLICAS" \
        --scale admin="$ADMIN_REPLICAS" \
        --scale app="$APP_REPLICAS" \
        --scale partner="$PARTNER_REPLICAS"
    if [[ "$ENV_PROFILE" == "local" ]]; then
        $COMPOSE up -d --force-recreate "$PROXY_SERVICE"
    fi
    reload_proxy
    echo ""
    ok "Containers started:"
    $COMPOSE ps
    echo ""
    if [[ "$ENV_PROFILE" == "local" ]]; then
        echo -e "  ${BOLD}API${NC}      -> http://localhost:${SERVER_PORT}"
        echo -e "  ${BOLD}Reporting${NC}-> http://localhost:${REPORTING_PORT}"
        echo -e "  ${BOLD}Admin${NC}    -> http://localhost:${ADMIN_PORT}"
        echo -e "  ${BOLD}App${NC}      -> http://localhost:${APP_PORT}"
        echo -e "  ${BOLD}Partner${NC}  -> http://localhost:${PARTNER_PORT}"
        if observability_enabled; then
            echo -e "  ${BOLD}SigNoz${NC}   -> http://localhost:${SIGNOZ_HTTP_PORT:-9080}"
            echo -e "  ${BOLD}Portainer${NC}-> https://localhost:${PORTAINER_HTTPS_PORT:-9443} (UI), http://localhost:${PORTAINER_HTTP_PORT:-8000} (agent)"
        else
            echo -e "  ${BOLD}Observability${NC}-> disabled"
        fi
    else
        echo -e "  ${BOLD}API${NC}      -> https://${API_DOMAIN}"
        echo -e "  ${BOLD}Reporting${NC}-> https://${REPORTING_DOMAIN}"
        echo -e "  ${BOLD}Admin${NC}    -> https://${ADMIN_DOMAIN}"
        echo -e "  ${BOLD}App${NC}      -> https://${APP_DOMAIN}"
        echo -e "  ${BOLD}Apex App${NC} -> https://${APEX_APP_DOMAIN} -> https://${APP_DOMAIN}"
        echo -e "  ${BOLD}Partner${NC}  -> https://${PARTNER_DOMAIN}"
        if observability_enabled; then
            echo -e "  ${BOLD}SigNoz${NC}   -> https://${SIGNOZ_DOMAIN}"
            echo -e "  ${BOLD}Portainer${NC}-> https://${PORTAINER_DOMAIN}"
            echo -e "  ${BOLD}OTEL${NC}     -> https://${MONITOR_DOMAIN}"
        else
            echo -e "  ${BOLD}Observability${NC}-> disabled"
        fi
    fi
    echo ""
}

app_image_for() {
    local service="$1"
    local registry="${IMAGE_REGISTRY:-ghcr.io/jeraldvictor}"
    registry="${registry%/}"

    case "$service" in
        server)    echo "${SERVER_IMAGE:-${registry}/hom-swag-server:${SERVER_IMAGE_TAG:-latest}}" ;;
        reporting) echo "${REPORTING_IMAGE:-${registry}/hom-swag-reporting:${REPORTING_IMAGE_TAG:-latest}}" ;;
        admin)     echo "${ADMIN_IMAGE:-${registry}/hom-swag-admin:${ADMIN_IMAGE_TAG:-latest}}" ;;
        app)       echo "${APP_IMAGE:-${registry}/hom-swag-app:${APP_IMAGE_TAG:-latest}}" ;;
        partner)   echo "${PARTNER_IMAGE:-${registry}/hom-swag-partner:${PARTNER_IMAGE_TAG:-latest}}" ;;
        *)         die "Unknown app service: $service" ;;
    esac
}

replicas_for() {
    case "$1" in
        server)    echo "$SERVER_REPLICAS" ;;
        reporting) echo "$REPORTING_REPLICAS" ;;
        admin)     echo "$ADMIN_REPLICAS" ;;
        app)       echo "$APP_REPLICAS" ;;
        partner)   echo "$PARTNER_REPLICAS" ;;
        *)         die "Unknown app service: $1" ;;
    esac
}

health_target_for() {
    case "$1" in
        server)    echo "3000 /health" ;;
        reporting) echo "3000 /health" ;;
        admin)     echo "80 /" ;;
        app)       echo "3000 /" ;;
        partner)   echo "80 /" ;;
        *)         die "Unknown app service: $1" ;;
    esac
}

deploy_replicas_for() {
    local normal
    local minimum
    normal="$(replicas_for "$1")"
    minimum=$(( normal * 2 ))
    if [[ "$DEPLOY_REPLICAS" -gt "$minimum" ]]; then
        echo "$DEPLOY_REPLICAS"
    else
        echo "$minimum"
    fi
}

print_server_health_response() {
    local response="$1"
    warn "server responded but reports UNHEALTHY sub-services"
    local sub
    for sub in Server MongoDB Redis MinIO Kafka; do
        local sub_line
        local sub_error
        sub_line=$(echo "$response" | grep -o "\"service\":\"$sub\",\"status\":\"[^\"]*\"" || true)
        sub_error=$(echo "$response" | grep -o "\"service\":\"$sub\"[^}]*\"error\":\"[^\"]*\"" | sed 's/.*"error":"\([^"]*\)".*/\1/' || true)
        if [[ -n "$sub_line" ]]; then
            local sub_status
            sub_status=$(echo "$sub_line" | sed 's/.*"status":"\([^"]*\)".*/\1/')
            if [[ "$sub_status" == "healthy" ]]; then
                echo -e "      ${GREEN}•${NC} $sub: $sub_status"
            else
                echo -e "      ${RED}•${NC} $sub: $sub_status"
                if [[ -n "$sub_error" ]]; then
                    echo -e "        ${YELLOW}${sub_error}${NC}"
                fi
            fi
        fi
    done
}

reload_proxy() {
    if ! $COMPOSE ps -q "$PROXY_SERVICE" 2>/dev/null | grep -q .; then
        return
    fi

    if [[ "$PROXY_STACK" == "nginx" ]]; then
        log "Reloading nginx ..."
        $COMPOSE exec -T "$PROXY_SERVICE" nginx -s reload >/dev/null 2>&1 || warn "nginx reload failed; container restart may still pick up config."
    else
        log "Reloading Caddy ..."
        $COMPOSE exec -T "$PROXY_SERVICE" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || warn "Caddy reload failed; container restart may still pick up config."
    fi
}

should_prune_images() {
    local default_prune="false"
    if [[ "$ENV_PROFILE" == "prod" || "$ENV_PROFILE" == "production" ]]; then
        default_prune="true"
    fi

    case "${PRUNE_AFTER_DEPLOY:-$default_prune}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

prune_images_after_deploy() {
    if should_prune_images; then
        log "Pruning dangling images ..."
        docker image prune -f
    else
        log "Skipping image prune (PRUNE_AFTER_DEPLOY=${PRUNE_AFTER_DEPLOY:-auto})"
    fi
}

remove_outdated_service_containers() {
    local service="$1"
    local image="$2"
    local desired="$3"
    local new_image_id
    new_image_id="$(docker image inspect "$image" --format '{{.Id}}')" || die "Unable to inspect pulled image: $image"

    local cid
    for cid in $($COMPOSE ps -q "$service"); do
        local container_image_id
        container_image_id="$(docker inspect "$cid" --format '{{.Image}}')"
        if [[ "$container_image_id" != "$new_image_id" ]]; then
            log "Removing old $service container $cid"
            docker rm -f "$cid" >/dev/null
        fi
    done

    $COMPOSE up -d --no-recreate --scale "$service=$desired" "$service"
}

container_ip() {
    docker inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

container_name() {
    docker inspect "$1" --format '{{.Name}}' | sed 's#^/##'
}

probe_container_from_proxy() {
    local cid="$1"
    local port="$2"
    local path="$3"
    local ip
    ip="$(container_ip "$cid")"
    [[ -n "$ip" ]] || return 1

    $COMPOSE exec -T "$PROXY_SERVICE" wget -q -O /dev/null --timeout=5 "http://${ip}:${port}${path}" >/dev/null 2>&1
}

wait_for_new_service_containers() {
    local service="$1"
    local image="$2"
    local desired="$3"
    local max_wait="${HEALTH_TIMEOUT:-90}"
    local interval=5
    local elapsed=0
    local new_image_id
    local target
    local port
    local path

    new_image_id="$(docker image inspect "$image" --format '{{.Id}}')" || die "Unable to inspect pulled image: $image"
    target="$(health_target_for "$service")"
    port="${target%% *}"
    path="${target#* }"

    log "Waiting for $desired new $service container(s) to pass direct health checks ..."
    while [[ "$elapsed" -lt "$max_wait" ]]; do
        local healthy=0
        local cid
        for cid in $($COMPOSE ps -q "$service"); do
            local container_image_id
            local running
            container_image_id="$(docker inspect "$cid" --format '{{.Image}}')"
            running="$(docker inspect "$cid" --format '{{.State.Running}}')"
            if [[ "$container_image_id" == "$new_image_id" && "$running" == "true" ]]; then
                if probe_container_from_proxy "$cid" "$port" "$path"; then
                    healthy=$(( healthy + 1 ))
                fi
            fi
        done

        if [[ "$healthy" -ge "$desired" ]]; then
            ok "$service has $healthy healthy new-image container(s)."
            return
        fi

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    warn "$service new-image containers did not become healthy within ${max_wait}s"
    local cid
    for cid in $($COMPOSE ps -q "$service"); do
        local container_image_id
        container_image_id="$(docker inspect "$cid" --format '{{.Image}}')"
        if [[ "$container_image_id" == "$new_image_id" ]]; then
            warn "New $service container still unhealthy: $(container_name "$cid") ($cid)"
        fi
    done
    exit 1
}

wait_for_new_app_containers() {
    local service
    for service in server reporting admin app partner; do
        wait_for_new_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
    done
}

# ---------------------------------------------------------------------------
# cmd_safe_deploy — graceful production deployment
#
# Flow:
#   1. Pull new images while live containers keep serving traffic.
#   2. Scale app services up behind the selected proxy using the newly pulled images.
#   3. Validate the new-image containers directly through the proxy network.
#   4. Validate the public proxy/SSL routes.
#   5. Remove containers still running old image IDs.
#   6. Settle services back to their configured replica counts.
# ---------------------------------------------------------------------------
cmd_safe_deploy() {
    ensure_persistent_mounts
    cmd_pull

    if ! $COMPOSE ps --quiet 2>/dev/null | grep -q .; then
        log "No existing stack detected — performing standard deploy"
        cmd_up
        cmd_health
        run_report_seed_if_enabled
        prune_images_after_deploy
        ok "Deploy complete."
        return
    fi

    echo ""
    echo -e "${BOLD}━━━  Scaling new replicas  ━━━${NC}"
    local server_deploy_replicas reporting_deploy_replicas admin_deploy_replicas app_deploy_replicas partner_deploy_replicas
    server_deploy_replicas="$(deploy_replicas_for server)"
    reporting_deploy_replicas="$(deploy_replicas_for reporting)"
    admin_deploy_replicas="$(deploy_replicas_for admin)"
    app_deploy_replicas="$(deploy_replicas_for app)"
    partner_deploy_replicas="$(deploy_replicas_for partner)"
    log "Starting extra app replicas behind $PROXY_SERVICE"
    $COMPOSE up -d --remove-orphans kafka
    $COMPOSE up -d --no-recreate --remove-orphans \
        --scale server="$server_deploy_replicas" \
        --scale reporting="$reporting_deploy_replicas" \
        --scale admin="$admin_deploy_replicas" \
        --scale app="$app_deploy_replicas" \
        --scale partner="$partner_deploy_replicas" \
        server reporting admin app partner "$PROXY_SERVICE"
    reload_proxy

    wait_for_new_app_containers
    cmd_health

    echo ""
    echo -e "${BOLD}━━━  Removing old app containers  ━━━${NC}"
    local service
    for service in server reporting admin app partner; do
        remove_outdated_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
        reload_proxy
        wait_for_new_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
    done
    $COMPOSE up -d --no-recreate --remove-orphans \
        --scale server="$SERVER_REPLICAS" \
        --scale reporting="$REPORTING_REPLICAS" \
        --scale admin="$ADMIN_REPLICAS" \
        --scale app="$APP_REPLICAS" \
        --scale partner="$PARTNER_REPLICAS" \
        "$PROXY_SERVICE"
    reload_proxy
    cmd_health
    run_report_seed_if_enabled

    prune_images_after_deploy
    ok "Graceful deploy complete."
}

cmd_deploy() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      HomSwag — Deploy                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo -e "  Env profile : ${BOLD}${ENV_PROFILE}${NC}  (${ENV_FILE})"
    echo ""

    if [[ "$ENV_PROFILE" == "prod" || "$ENV_PROFILE" == "production" ]]; then
        cmd_safe_deploy
    else
        cmd_pull
        cmd_up
        cmd_health
        run_report_seed_if_enabled
        # New stack is confirmed healthy before optional image cleanup.
        prune_images_after_deploy
        ok "Deploy complete."
    fi
}

cmd_health() {
    echo ""
    echo -e "${BOLD}━━━  Health validation  ━━━${NC}"

    local max_wait="${HEALTH_TIMEOUT:-90}"
    local interval=5
    local all_ok=true

    # Parallel arrays — avoids associative arrays (bash 3.2 on macOS)
    local svcs=("server" "reporting" "admin" "app" "apex-app" "partner")
    local domains=("$API_DOMAIN" "$REPORTING_DOMAIN" "$ADMIN_DOMAIN" "$APP_DOMAIN" "$APEX_APP_DOMAIN" "$PARTNER_DOMAIN")
    local paths=("/health" "/health" "/health" "/" "/" "/health")
    if observability_enabled; then
        svcs+=("app-otel" "signoz" "portainer" "otel-collector")
        domains+=("$APP_DOMAIN" "$SIGNOZ_DOMAIN" "$PORTAINER_DOMAIN" "$MONITOR_DOMAIN")
        paths+=("/otel/v1/traces" "/" "/" "/v1/traces")
    fi

    local i
    for i in "${!svcs[@]}"; do
        local svc="${svcs[$i]}"
        local domain="${domains[$i]}"
        local path="${paths[$i]}"
        local scheme="https"
        local port="$PROXY_HTTPS_PORT"
        local url
        if [[ "$svc" == "minio" ]]; then
            url="http://${LOCAL_HEALTH_HOST}:${MINIO_PORT:-9000}${path}"
        elif [[ "$svc" == "signoz" && "$ENV_PROFILE" == "local" ]]; then
            url="http://${LOCAL_HEALTH_HOST}:${SIGNOZ_HTTP_PORT:-8080}${path}"
        elif [[ "$svc" == "otel-collector" && "$ENV_PROFILE" == "local" ]]; then
            url="http://${LOCAL_HEALTH_HOST}:${OTEL_COLLECTOR_HEALTH_PORT:-13133}${path}"
        elif [[ "$svc" == "portainer" && "$ENV_PROFILE" == "local" ]]; then
            url="https://${LOCAL_HEALTH_HOST}:${PORTAINER_HTTPS_PORT:-9443}${path}"
        elif [[ "$ENV_PROFILE" == "local" ]]; then
            scheme="http"
            case "$svc" in
                server)    port="$SERVER_PORT" ;;
                reporting) port="$REPORTING_PORT" ;;
                admin)     port="$ADMIN_PORT" ;;
                app)       port="$APP_PORT" ;;
                partner)   port="$PARTNER_PORT" ;;
            esac
            url="${scheme}://${LOCAL_HEALTH_HOST}:${port}${path}"
        else
            url="${scheme}://${domain}:${port}${path}"
        fi
        local svc_ok=false
        local elapsed=0
        local last_server_health_response=""
        local fallback_url=""
        local check_url="$url"
        local target_message="$url"
        local successful_url="$url"
        if [[ "$svc" == "portainer" && "$ENV_PROFILE" == "local" ]]; then
            check_url="https://${LOCAL_HEALTH_HOST}:${PORTAINER_HTTPS_PORT:-9443}${path}"
            fallback_url="http://${LOCAL_HEALTH_HOST}:${PORTAINER_HTTP_PORT:-8000}${path}"
            target_message="$check_url (then $fallback_url)"
        fi

        log "Waiting for $svc at ${target_message} (timeout: ${max_wait}s) ..."
        while [[ "$elapsed" -lt "$max_wait" ]]; do
            local http_code
            local tmp_body

            tmp_body=$(mktemp /tmp/health_XXXXXX)
            if [[ "$svc" == "portainer" ]]; then
                http_code=$(curl -k -s -o "$tmp_body" -w "%{http_code}" --max-time 3 "$check_url" || echo "000")
                successful_url="$check_url"
                if [[ "$http_code" != "200" && "$http_code" != "204" && "$http_code" != "301" && "$http_code" != "302" && "$http_code" != "307" && "$http_code" != "308" ]]; then
                    http_code=$(curl -s -o "$tmp_body" -w "%{http_code}" --max-time 3 "$fallback_url" || echo "000")
                    successful_url="$fallback_url"
                fi
            elif [[ "$svc" == "minio" || "$ENV_PROFILE" == "local" ]]; then
                http_code=$(curl -s -o "$tmp_body" -w "%{http_code}" --max-time 3 "$url" || echo "000")
            elif [[ "$svc" == "otel-collector" || "$svc" == "app-otel" ]]; then
                http_code=$(curl -k -s -o "$tmp_body" -w "%{http_code}" --max-time 5 --resolve "${domain}:${port}:127.0.0.1" -H "Content-Type: application/json" --data '{}' "$url" || echo "000")
            else
                http_code=$(curl -k -s -o "$tmp_body" -w "%{http_code}" --max-time 5 --resolve "${domain}:${port}:127.0.0.1" "$url" || echo "000")
            fi
            if [[ "$svc" == "server" && "$http_code" != "000" ]]; then
                local response
                response=$(tr -d '\000' < "$tmp_body")
                if echo "$response" | grep -q '"services":'; then
                    last_server_health_response="$response"
                fi
            fi
            rm -f "$tmp_body"

            if [[ "$http_code" == "200" || "$http_code" == "204" || "$http_code" == "301" || "$http_code" == "302" || "$http_code" == "307" || "$http_code" == "308" ]]; then
                ok "$svc is up  ($successful_url)"
                svc_ok=true
                break
            fi
            sleep "$interval"
            elapsed=$(( elapsed + interval ))
        done

            if [[ "$svc_ok" == false ]]; then
            if [[ "$svc" == "server" && -n "$last_server_health_response" ]]; then
                print_server_health_response "$last_server_health_response"
                warn "$svc health did not become healthy at $url within ${max_wait}s"
            else
                warn "$svc did NOT respond at ${target_message} within ${max_wait}s"
            fi
            all_ok=false
        fi
    done

    echo ""
    if [[ "$all_ok" == true ]]; then
        ok "All services are healthy."
        cleanup_completed_local_jobs
    else
        warn "One or more services failed health checks. Run './deploy.sh logs' to investigate."
        exit 1
    fi
}

cleanup_completed_local_jobs() {
    if [[ "$ENV_PROFILE" != "local" ]]; then
        return
    fi

    local runtime="${COMPOSE_BIN%% *}"
    local svc
    for svc in minio-init; do
        local cid
        cid="$($COMPOSE ps -a -q "$svc" 2>/dev/null || true)"
        [[ -n "$cid" ]] || continue

        local state
        local exit_code
        state="$($runtime inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || true)"
        exit_code="$($runtime inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null || true)"
        if [[ "$state" == "exited" && "$exit_code" == "0" ]]; then
            log "Removing completed local job container: $svc"
            $COMPOSE rm -f "$svc" >/dev/null 2>&1 || true
        fi
    done
}

cmd_restart() {
    log "Restarting ${*:-all services} ..."
    $COMPOSE restart "$@"
    ok "Done"
    $COMPOSE ps
}

# Force-recreate one or all services without pulling new images
cmd_recreate() {
    local svcs=("$@")
    if [[ "${#svcs[@]}" -gt 0 ]]; then
        log "Force-recreating service(s): ${svcs[*]} ..."
    else
        log "Force-recreating all services ..."
    fi
    if [[ "${#svcs[@]}" -gt 0 ]]; then
        $COMPOSE up -d --force-recreate "${svcs[@]}"
    else
        $COMPOSE up -d --force-recreate
    fi
    ok "Done"
    $COMPOSE ps
}

# Pull latest image(s) then force-recreate — scoped to one or all services
cmd_refresh() {
    local svcs=("$@")
    if [[ "${#svcs[@]}" -gt 0 ]]; then
        log "Refreshing service(s): ${svcs[*]} ..."
        $COMPOSE pull "${svcs[@]}"
        $COMPOSE up -d --force-recreate "${svcs[@]}"
    else
        log "Refreshing all services ..."
        $COMPOSE pull
        $COMPOSE up -d --force-recreate
    fi
    ok "Done"
    $COMPOSE ps
}

# Full clean: remove the compose stack, pull fresh images, start, health check,
# then prune old images. Volumes are removed when CLEAN_REMOVE_VOLUMES=true.
cmd_clean() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      HomSwag — Clean Deploy          ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo -e "  Env profile : ${BOLD}${ENV_PROFILE}${NC}  (${ENV_FILE})"
    echo -e "  Remove volumes : ${BOLD}${CLEAN_REMOVE_VOLUMES:-false}${NC}"
    echo ""

    warn "Stopping and removing the current compose stack ..."
    if [[ "${CLEAN_REMOVE_VOLUMES:-false}" == "true" ]]; then
        $COMPOSE down --remove-orphans --volumes || true
    else
        $COMPOSE down --remove-orphans || true
    fi

    cmd_pull
    cmd_up
    cmd_health
    prune_images_after_deploy
    ok "Clean deploy complete."
}

cmd_down() {
    warn "Stopping all containers (data volumes are preserved) ..."
    $COMPOSE down || true
    ok "All containers stopped"
}

# Remove ALL unused containers, images, networks and volumes (full Docker cleanup)
cmd_prune() {
    warn "This will remove ALL unused Docker resources (containers, images, networks, volumes)."
    warn "Running: docker system prune -a --volumes"
    read -r -p "Are you sure? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
    docker system prune -a --volumes
    ok "Docker system pruned."
}

# Tail last 100 lines and follow
cmd_logs() {
    $COMPOSE logs -f --tail=100 "$@"
}

# Dump last 100 lines without following
cmd_logs_dump() {
    local svc="${1:-}"
    [[ -n "$svc" ]] || die "Usage: ./deploy.sh dump <service>"
    log "Last 100 lines of $svc:"
    $COMPOSE logs --tail=100 "$svc"
}

# Dump ALL logs for a service (no tail limit)
cmd_logs_all() {
    local svc="${1:-}"
    [[ -n "$svc" ]] || die "Usage: ./deploy.sh logs-all <service>"
    log "All logs for $svc:"
    $COMPOSE logs --no-log-prefix "$svc"
}

# Open an interactive shell inside a running container
cmd_shell() {
    local svc="${1:-}"
    [[ -n "$svc" ]] || die "Usage: ./deploy.sh shell <service>"
    log "Opening shell in compose service: $svc"
    $COMPOSE exec "$svc" sh -c 'which bash > /dev/null 2>&1 && exec bash || exec sh'
}

cmd_exec() {
    local svc="${1:-}"
    [[ -n "$svc" ]] || die "Usage: ./deploy.sh exec <service> -- <command...>"
    shift || true
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    [[ "$#" -gt 0 ]] || die "Usage: ./deploy.sh exec <service> -- <command...>"
    log "Running in compose service '$svc': $*"
    $COMPOSE exec "$svc" "$@"
}

cmd_status() {
    $COMPOSE ps
}

cmd_memory() {
    local service="server"
    if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
        service="$1"
        shift
    fi

    if [[ "$service" != "server" ]]; then
        local argument
        for argument in "$@"; do
            [[ "$argument" != "--node-report" ]] || die "--node-report is supported only for the server service"
        done
    fi

    local container_id
    container_id="$($COMPOSE ps -q "$service" 2>/dev/null | sed -n '1p')"
    [[ -n "$container_id" ]] || die "Compose service '$service' is not running"

    ensure_host_mount_dir "Memory reports" "${MEMORY_REPORTS_PATH:-./memory-diagnostics}"
    log "Collecting VPS and '$service' memory evidence (container ${container_id:0:12}) ..."
    ./scripts/analyze-memory.sh \
        --runtime "${COMPOSE_BIN%% *}" \
        --container "$container_id" \
        --output "${MEMORY_REPORTS_PATH:-./memory-diagnostics}" \
        "$@"
}

cmd_valkey() {
    local action="${1:-status}"
    if [[ "$#" -gt 0 ]]; then
        shift
    fi
    case "$action" in
        status|cleanup|guard|help|-h|--help) ;;
        *) die "Usage: ./deploy.sh valkey {status|cleanup|guard} [--threshold 60] [--apply]" ;;
    esac

    local container_id
    container_id="$($COMPOSE ps -q server 2>/dev/null | sed -n '1p')"
    [[ -n "$container_id" ]] || die "Compose service 'server' is not running"

    log "Running Valkey '$action' from the server container (credentials are not printed) ..."
    $COMPOSE exec -T server env \
        VALKEY_MEMORY_WARN_PERCENT="${VALKEY_MEMORY_WARN_PERCENT:-60}" \
        node --input-type=module - "$action" "$@" < ./scripts/valkey-memory.mjs
}

cmd_cleanup_storage() {
    local cleanup_args=(
        --root "$SCRIPT_DIR"
        --runtime "${COMPOSE_BIN%% *}"
        --logs-dir "${LOG_PATH:-./logs}"
        --uploads-dir "${UPLOAD_SOURCE:-./uploads}/temp"
        --diagnostics-dir "${DIAGNOSTICS_SOURCE:-./diagnostics}"
        --memory-reports-dir "${MEMORY_REPORTS_PATH:-./memory-diagnostics}"
        --logs-days "${CLEANUP_LOG_DAYS:-7}"
        --temp-hours "${CLEANUP_TEMP_HOURS:-24}"
        --diagnostics-days "${CLEANUP_DIAGNOSTICS_DAYS:-7}"
    )

    local reporting_container
    while IFS= read -r reporting_container; do
        [[ -n "$reporting_container" ]] && cleanup_args+=(--reporting-container "$reporting_container")
    done < <($COMPOSE ps -q reporting 2>/dev/null || true)

    ./scripts/cleanup-vps.sh "${cleanup_args[@]}" "$@"
}

# Run the compiled seed script inside the server container
cmd_seed() {
    log "Running seed in compose service: server ..."
    $COMPOSE exec server node dist/seed.cjs "$@"
    ok "Seed complete"
}

# Non-destructively upsert report definitions used by the reporting dashboard.
cmd_seed_reports() {
    cmd_seed --upsert --only=reports
}

run_report_seed_if_enabled() {
    if ! is_truthy "${AUTO_SEED_REPORT_DEFINITIONS:-true}"; then
        log "AUTO_SEED_REPORT_DEFINITIONS is disabled. Skipping report-definition seed."
        return
    fi

    if ! $COMPOSE ps -q server >/dev/null 2>&1 || ! $COMPOSE ps -q server | grep -q .; then
        warn "Server service is not running; skipping report-definition seed."
        warn "Run './deploy.sh seed-reports' after the stack is up."
        return
    fi

    log "Running report-definition seed (upsert mode) ..."
    cmd_seed_reports
}

# =============================================================================
# Entrypoint
# =============================================================================

case "$COMMAND" in
    deploy|"")  cmd_deploy             ;;
    pull)       cmd_pull               ;;
    up)         cmd_up                 ;;
    restart)    cmd_restart   "$@"     ;;
    recreate)   cmd_recreate  "$@"     ;;
    refresh)    cmd_refresh   "$@"     ;;
    clean)      cmd_clean              ;;
    down)       cmd_down               ;;
    prune)      cmd_prune              ;;
    logs)       cmd_logs      "$@"     ;;
    dump)       cmd_logs_dump "$@"     ;;
    logs-all)   cmd_logs_all  "$@"     ;;
    shell)      cmd_shell     "$@"     ;;
    exec)       cmd_exec      "$@"     ;;
    status)     cmd_status             ;;
    health)     cmd_health             ;;
    memory)     cmd_memory     "$@"    ;;
    valkey)     cmd_valkey     "$@"    ;;
    cleanup)    cmd_cleanup_storage "$@" ;;
    help)       print_help             ;;
    certs)      cmd_certs              ;;
    seed)       cmd_seed      "$@"     ;;
    seed-reports) cmd_seed_reports     ;;
    *)
        print_help
        exit 1
        ;;
esac
