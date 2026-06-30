#!/usr/bin/env bash
# =============================================================================
# HomSwag — Deploy script (image-based — no git pull, no local build)
#
# Usage:
#   ./deploy.sh                      # pull images from registry + start all services
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
#   ./deploy.sh status               # show running containers
#   ./deploy.sh health               # validate service HTTP endpoints
#   ./deploy.sh certs                # issue/renew trusted Let's Encrypt TLS certs
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

# ── Parse global flags ─────────────────────────────────────────────────────────
ENV_PROFILE="${DEPLOY_ENV:-local}"
COMMAND=""
REMAINING_ARGS=()
UNKNOWN_ARGS=()

is_command() {
    case "$1" in
        deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|status|health|certs|seed|seed-reports)
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
    die "Unknown command '${UNKNOWN_ARGS[0]}'. Use: ${0} [--env local|prod] {deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|status|health|certs|seed|seed-reports}"
fi

if [[ -z "$COMMAND" ]]; then
    COMMAND="deploy"
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

# ── Discover compose binary ────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    COMPOSE_BIN="docker compose"
elif command -v podman &>/dev/null; then
    warn "docker not found — falling back to podman compose"
    COMPOSE_BIN="podman compose"
else
    die "Neither docker nor podman found. Please install one of them."
fi

COMPOSE="$COMPOSE_BIN --env-file $ENV_FILE -f compose.yaml"

# ── Port defaults (overridden by env file if set) ──────────────────────────────
SERVER_PORT="${SERVER_PORT:-3000}"
ADMIN_PORT="${ADMIN_PORT:-3001}"
APP_PORT="${APP_PORT:-3002}"
REPORTING_PORT="${REPORTING_PORT:-3003}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
APP_DOMAIN="${APP_DOMAIN:-alpha.homswag.com}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-admin.alpha.homswag.com}"
API_DOMAIN="${API_DOMAIN:-api.alpha.homswag.com}"
REPORTING_DOMAIN="${REPORTING_DOMAIN:-reporting.alpha.homswag.com}"
SERVER_REPLICAS="${SERVER_REPLICAS:-1}"
REPORTING_REPLICAS="${REPORTING_REPLICAS:-1}"
ADMIN_REPLICAS="${ADMIN_REPLICAS:-1}"
APP_REPLICAS="${APP_REPLICAS:-1}"
DEPLOY_REPLICAS="${DEPLOY_REPLICAS:-2}"

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

ensure_nginx_certs() {
    local certs_path="${NGINX_CERTS_PATH:-./nginx/certs}"
    [[ "$certs_path" = /* ]] || certs_path="${SCRIPT_DIR}/${certs_path}"

    local domain
    for domain in "$API_DOMAIN" "$REPORTING_DOMAIN" "$ADMIN_DOMAIN" "$APP_DOMAIN"; do
        local cert_dir="${certs_path}/${domain}"
        local cert_file="${cert_dir}/fullchain.pem"
        local key_file="${cert_dir}/privkey.pem"

        if [[ -s "$cert_file" && -s "$key_file" ]]; then
            continue
        fi

        warn "Missing TLS certificate for ${domain}; creating temporary self-signed cert"
        mkdir -p "$cert_dir"
        openssl req -x509 -nodes -newkey rsa:2048 -days 7 \
            -subj "/CN=${domain}" \
            -addext "subjectAltName=DNS:${domain}" \
            -keyout "$key_file" \
            -out "$cert_file" >/dev/null 2>&1 || die "Failed to create temporary TLS certificate for ${domain}"
    done
}

copy_letsencrypt_cert() {
    local domain="$1"
    local certs_path="${NGINX_CERTS_PATH:-./nginx/certs}"
    [[ "$certs_path" = /* ]] || certs_path="${SCRIPT_DIR}/${certs_path}"

    local source_dir="${SCRIPT_DIR}/nginx/letsencrypt/live/${domain}"
    local target_dir="${certs_path}/${domain}"

    [[ -s "${source_dir}/fullchain.pem" && -s "${source_dir}/privkey.pem" ]] || \
        die "Let's Encrypt did not create expected cert files for ${domain}"

    mkdir -p "$target_dir"
    cp -L "${source_dir}/fullchain.pem" "${target_dir}/fullchain.pem"
    cp -L "${source_dir}/privkey.pem" "${target_dir}/privkey.pem"
}

verify_trusted_cert() {
    local domain="$1"
    local certs_path="${NGINX_CERTS_PATH:-./nginx/certs}"
    [[ "$certs_path" = /* ]] || certs_path="${SCRIPT_DIR}/${certs_path}"

    local cert_file="${certs_path}/${domain}/fullchain.pem"
    [[ -s "$cert_file" ]] || die "Missing installed certificate for ${domain}"

    local subject issuer
    subject="$(openssl x509 -in "$cert_file" -noout -subject)"
    issuer="$(openssl x509 -in "$cert_file" -noout -issuer)"

    if [[ "$subject" == "$issuer" ]]; then
        die "Installed certificate for ${domain} is self-signed. Check Certbot output and DNS/port 80 reachability."
    fi

    if ! openssl x509 -in "$cert_file" -noout -checkend 1209600 >/dev/null; then
        die "Installed certificate for ${domain} expires within 14 days."
    fi
}

cmd_certs() {
    echo ""
    echo -e "${BOLD}━━━  Issuing trusted TLS certificates  ━━━${NC}"

    [[ "$ENV_PROFILE" == "prod" || "$ENV_PROFILE" == "production" ]] || \
        warn "Issuing public Let's Encrypt certs for non-prod profile '${ENV_PROFILE}'"

    local email="${LETSENCRYPT_EMAIL:-}"
    [[ -n "$email" ]] || die "Set LETSENCRYPT_EMAIL in ${ENV_FILE} before issuing certificates."

    mkdir -p "${SCRIPT_DIR}/nginx/certbot" "${SCRIPT_DIR}/nginx/letsencrypt"
    ensure_nginx_certs

    log "Starting nginx so Let's Encrypt can reach HTTP-01 challenge paths ..."
    $COMPOSE up -d nginx

    local domains=("$APP_DOMAIN" "$ADMIN_DOMAIN" "$API_DOMAIN" "$REPORTING_DOMAIN")
    local domain
    for domain in "${domains[@]}"; do
        log "Requesting certificate for: ${domain}"
        $COMPOSE --profile certbot run --rm certbot certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --email "$email" \
            --agree-tos \
            --no-eff-email \
            --keep-until-expiring \
            -d "$domain"
        copy_letsencrypt_cert "$domain"
        verify_trusted_cert "$domain"
    done

    reload_nginx
    ok "Trusted TLS certificates installed."
}

cmd_pull() {
    echo ""
    echo -e "${BOLD}━━━  Pulling images from registry  ━━━${NC}"
    log "Using env file: $ENV_FILE"
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
    ensure_nginx_certs
    $COMPOSE up -d --remove-orphans \
        --scale server="$SERVER_REPLICAS" \
        --scale reporting="$REPORTING_REPLICAS" \
        --scale admin="$ADMIN_REPLICAS" \
        --scale app="$APP_REPLICAS"
    echo ""
    ok "Containers started:"
    $COMPOSE ps
    echo ""
    echo -e "  ${BOLD}API${NC}      -> https://${API_DOMAIN}"
    echo -e "  ${BOLD}Reporting${NC}-> https://${REPORTING_DOMAIN}"
    echo -e "  ${BOLD}Admin${NC}    -> https://${ADMIN_DOMAIN}"
    echo -e "  ${BOLD}App${NC}      -> https://${APP_DOMAIN}"
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
        *)         die "Unknown app service: $service" ;;
    esac
}

replicas_for() {
    case "$1" in
        server)    echo "$SERVER_REPLICAS" ;;
        reporting) echo "$REPORTING_REPLICAS" ;;
        admin)     echo "$ADMIN_REPLICAS" ;;
        app)       echo "$APP_REPLICAS" ;;
        *)         die "Unknown app service: $1" ;;
    esac
}

health_target_for() {
    case "$1" in
        server)    echo "3000 /health" ;;
        reporting) echo "3000 /health" ;;
        admin)     echo "80 /" ;;
        app)       echo "3000 /" ;;
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

reload_nginx() {
    if $COMPOSE ps -q nginx 2>/dev/null | grep -q .; then
        log "Reloading nginx ..."
        $COMPOSE exec -T nginx nginx -s reload >/dev/null 2>&1 || warn "nginx reload failed; container restart may still pick up config."
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

probe_container_from_nginx() {
    local cid="$1"
    local port="$2"
    local path="$3"
    local ip
    ip="$(container_ip "$cid")"
    [[ -n "$ip" ]] || return 1

    $COMPOSE exec -T nginx wget -q -O /dev/null --timeout=5 "http://${ip}:${port}${path}" >/dev/null 2>&1
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
                if probe_container_from_nginx "$cid" "$port" "$path"; then
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
    for service in server reporting admin app; do
        wait_for_new_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
    done
}

# ---------------------------------------------------------------------------
# cmd_safe_deploy — graceful production deployment
#
# Flow:
#   1. Pull new images while live containers keep serving traffic.
#   2. Scale app services up behind nginx using the newly pulled images.
#   3. Validate the new-image containers directly through the nginx network.
#   4. Validate the public nginx/SSL routes.
#   5. Remove containers still running old image IDs.
#   6. Settle services back to their configured replica counts.
# ---------------------------------------------------------------------------
cmd_safe_deploy() {
    cmd_pull

    if ! $COMPOSE ps --quiet 2>/dev/null | grep -q .; then
        log "No existing stack detected — performing standard deploy"
        cmd_up
        cmd_health
        log "Pruning dangling images ..."
        docker image prune -f
        ok "Deploy complete."
        return
    fi

    echo ""
    echo -e "${BOLD}━━━  Scaling new replicas  ━━━${NC}"
    local server_deploy_replicas reporting_deploy_replicas admin_deploy_replicas app_deploy_replicas
    server_deploy_replicas="$(deploy_replicas_for server)"
    reporting_deploy_replicas="$(deploy_replicas_for reporting)"
    admin_deploy_replicas="$(deploy_replicas_for admin)"
    app_deploy_replicas="$(deploy_replicas_for app)"
    log "Starting extra app replicas behind nginx"
    $COMPOSE up -d --remove-orphans kafka
    $COMPOSE up -d --no-recreate --remove-orphans \
        --scale server="$server_deploy_replicas" \
        --scale reporting="$reporting_deploy_replicas" \
        --scale admin="$admin_deploy_replicas" \
        --scale app="$app_deploy_replicas" \
        server reporting admin app nginx
    reload_nginx

    wait_for_new_app_containers
    cmd_health

    echo ""
    echo -e "${BOLD}━━━  Removing old app containers  ━━━${NC}"
    local service
    for service in server reporting admin app; do
        remove_outdated_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
        reload_nginx
        wait_for_new_service_containers "$service" "$(app_image_for "$service")" "$(replicas_for "$service")"
    done
    $COMPOSE up -d --no-recreate --remove-orphans \
        --scale server="$SERVER_REPLICAS" \
        --scale reporting="$REPORTING_REPLICAS" \
        --scale admin="$ADMIN_REPLICAS" \
        --scale app="$APP_REPLICAS" \
        nginx
    reload_nginx
    cmd_health

    log "Pruning dangling images ..."
    docker image prune -f
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
        # New stack is confirmed healthy — prune dangling/old images
        log "Pruning dangling images ..."
        docker image prune -f
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
    local svcs=("server" "reporting" "admin" "app")
    local domains=("$API_DOMAIN" "$REPORTING_DOMAIN" "$ADMIN_DOMAIN" "$APP_DOMAIN")
    local paths=("/health" "/health" "/health" "/")

    local i
    for i in "${!svcs[@]}"; do
        local svc="${svcs[$i]}"
        local domain="${domains[$i]}"
        local path="${paths[$i]}"
        local url
        if [[ "$svc" == "minio" ]]; then
            url="http://localhost:${MINIO_PORT:-9000}${path}"
        else
            url="https://${domain}:${NGINX_HTTPS_PORT}${path}"
        fi
        local svc_ok=false
        local elapsed=0
        local last_server_health_response=""

        log "Waiting for $svc at $url (timeout: ${max_wait}s) ..."
        while [[ "$elapsed" -lt "$max_wait" ]]; do
            local http_code
            local tmp_body

            tmp_body=$(mktemp /tmp/health_XXXXXX)
            if [[ "$svc" == "minio" ]]; then
                http_code=$(curl -s -o "$tmp_body" -w "%{http_code}" --max-time 3 "$url" || echo "000")
            else
                http_code=$(curl -k -s -o "$tmp_body" -w "%{http_code}" --max-time 5 --resolve "${domain}:${NGINX_HTTPS_PORT}:127.0.0.1" "$url" || echo "000")
            fi
            if [[ "$svc" == "server" && "$http_code" != "000" ]]; then
                local response
                response=$(tr -d '\000' < "$tmp_body")
                if echo "$response" | grep -q '"services":'; then
                    last_server_health_response="$response"
                fi
            fi
            rm -f "$tmp_body"

            if [[ "$http_code" == "200" ]]; then
                ok "$svc is up  ($url)"
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
                warn "$svc did NOT respond at $url within ${max_wait}s"
            fi
            all_ok=false
        fi
    done

    echo ""
    if [[ "$all_ok" == true ]]; then
        ok "All services are healthy."
    else
        warn "One or more services failed health checks. Run './deploy.sh logs' to investigate."
        exit 1
    fi
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
    ensure_nginx_certs
    if [[ "${#svcs[@]}" -gt 0 ]]; then
        log "Force-recreating service(s): ${svcs[*]} ..."
    else
        log "Force-recreating all services ..."
    fi
    $COMPOSE up -d --force-recreate "${svcs[@]}"
    ok "Done"
    $COMPOSE ps
}

# Pull latest image(s) then force-recreate — scoped to one or all services
cmd_refresh() {
    local svcs=("$@")
    ensure_nginx_certs
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
    log "Pruning dangling images ..."
    docker image prune -f
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

cmd_status() {
    $COMPOSE ps
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
    status)     cmd_status             ;;
    health)     cmd_health             ;;
    certs)      cmd_certs              ;;
    seed)       cmd_seed      "$@"     ;;
    seed-reports) cmd_seed_reports     ;;
    *)
        echo ""
        echo "Usage: $0 [--env local|prod] {deploy|pull|up|restart|recreate|refresh|clean|down|prune|logs|dump|logs-all|shell|status|health|certs|seed|seed-reports}"
        echo ""
        echo "  deploy    Pull images then start all services (default)"
        echo "  pull      Pull latest images from the configured registry only"
        echo "  up        Start services without pulling images"
        echo "  restart   Restart containers          (e.g. ./deploy.sh restart server)"
        echo "  recreate  Force-recreate containers   (e.g. ./deploy.sh recreate server)"
        echo "  refresh   Pull + force-recreate       (e.g. ./deploy.sh refresh server)"
        echo "  clean     Remove stack, pull fresh images, start, verify health, then prune"
        echo "  down      Stop and remove containers (volumes kept)"
        echo "  prune     Remove ALL unused Docker resources (docker system prune -a --volumes)"
        echo "  logs      Follow logs, last 100 lines  (e.g. ./deploy.sh logs app)"
        echo "  dump      Print last 100 lines, no follow (e.g. ./deploy.sh dump app)"
        echo "  logs-all  Print ALL logs for a service   (e.g. ./deploy.sh logs-all server)"
        echo "  shell     Open terminal in container     (e.g. ./deploy.sh shell server)"
        echo "  status    Show running containers"
        echo "  health    Validate service HTTP endpoints"
        echo "  certs     Issue/renew trusted Let's Encrypt TLS certificates"
        echo "  seed      Run database seed inside the server container"
        echo "             (e.g. ./deploy.sh seed --upsert --only=locations,offices,menu,products)"
        echo "  seed-reports  Upsert report definitions only"
        echo ""
        exit 1
        ;;
esac
