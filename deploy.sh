#!/usr/bin/env bash
# =============================================================================
# HomSwag — Deploy script (image-based — no git pull, no local build)
#
# Usage:
#   ./deploy.sh                      # pull images from GHCR + start all services
#   ./deploy.sh --env prod           # use .env.prod instead of .env.local
#   ./deploy.sh pull                 # pull latest images only
#   ./deploy.sh up                   # start services (skip image pull)
#   ./deploy.sh restart [svc...]     # restart one or all containers
#   ./deploy.sh down                 # stop and remove containers (volumes kept)
#   ./deploy.sh logs [svc...]        # tail logs
#   ./deploy.sh status               # show running containers
#   ./deploy.sh health               # validate service HTTP endpoints
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

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -e|--env)
            [[ "$#" -ge 2 ]] || die "Missing value for --env (expected: local|prod)"
            ENV_PROFILE="$2"
            shift 2
            ;;
        *) break ;;
    esac
done

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
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

# =============================================================================
# Sub-commands
# =============================================================================

cmd_pull() {
    echo ""
    echo -e "${BOLD}━━━  Pulling images from GHCR  ━━━${NC}"
    log "Using env file: $ENV_FILE"
    $COMPOSE pull
    ok "All images up-to-date"
}

cmd_up() {
    echo ""
    echo -e "${BOLD}━━━  Starting services  ━━━${NC}"
    $COMPOSE up -d
    echo ""
    ok "Containers started:"
    $COMPOSE ps
    echo ""
    echo -e "  ${BOLD}Server${NC}   -> http://localhost:${SERVER_PORT}"
    echo -e "  ${BOLD}Admin${NC}    -> http://localhost:${ADMIN_PORT}"
    echo -e "  ${BOLD}App${NC}      -> http://localhost:${APP_PORT}"
    echo -e "  ${BOLD}MinIO${NC}    -> http://localhost:${MINIO_CONSOLE_PORT}  (console)"
    echo ""
}

cmd_deploy() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      HomSwag — Deploy                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo -e "  Env profile : ${BOLD}${ENV_PROFILE}${NC}  (${ENV_FILE})"
    echo ""
    cmd_pull
    cmd_up
    cmd_health
}

cmd_health() {
    echo ""
    echo -e "${BOLD}━━━  Health validation  ━━━${NC}"

    local max_wait="${HEALTH_TIMEOUT:-90}"
    local interval=5
    local all_ok=true

    # Parallel arrays — avoids associative arrays (bash 3.2 on macOS)
    local svcs=("server"                                  "admin"                       "app")
    local urls=("http://localhost:${SERVER_PORT}/health"  "http://localhost:${ADMIN_PORT}"  "http://localhost:${APP_PORT}")

    local i
    for i in 0 1 2; do
        local svc="${svcs[$i]}"
        local url="${urls[$i]}"
        local svc_ok=false
        local elapsed=0

        log "Waiting for $svc at $url (timeout: ${max_wait}s) ..."
        while [[ "$elapsed" -lt "$max_wait" ]]; do
            if curl -sf --max-time 3 "$url" &>/dev/null; then
                ok "$svc is up  ($url)"
                svc_ok=true
                break
            fi
            sleep "$interval"
            elapsed=$(( elapsed + interval ))
        done

        if [[ "$svc_ok" == false ]]; then
            warn "$svc did NOT respond at $url within ${max_wait}s"
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

# Full clean: stop containers, remove cached images, fresh pull, start
cmd_clean() {
    echo ""
    echo -e "${BOLD}━━━  Clean deploy  ━━━${NC}"
    warn "Stopping containers and removing cached images ..."
    $COMPOSE down --rmi all || true
    echo ""
    log "Pulling fresh images ..."
    $COMPOSE pull
    echo ""
    cmd_up
    cmd_health
}

cmd_down() {
    warn "Stopping all containers (data volumes are preserved) ..."
    $COMPOSE down || true
    ok "All containers stopped"
}

cmd_logs() {
    $COMPOSE logs -f --tail=100 "$@"
}

cmd_status() {
    $COMPOSE ps
}

# =============================================================================
# Entrypoint
# =============================================================================
COMMAND="${1:-deploy}"
shift || true

case "$COMMAND" in
    deploy|"")  cmd_deploy             ;;
    pull)       cmd_pull               ;;
    up)         cmd_up                 ;;
    restart)    cmd_restart   "$@"     ;;
    recreate)   cmd_recreate  "$@"     ;;
    refresh)    cmd_refresh   "$@"     ;;
    clean)      cmd_clean              ;;
    down)       cmd_down               ;;
    logs)       cmd_logs      "$@"     ;;
    status)     cmd_status             ;;
    health)     cmd_health             ;;
    *)
        echo ""
        echo "Usage: $0 [--env local|prod] {deploy|pull|up|restart|recreate|refresh|clean|down|logs|status|health}"
        echo ""
        echo "  deploy    Pull images then start all services (default)"
        echo "  pull      Pull latest images from GHCR only"
        echo "  up        Start services without pulling images"
        echo "  restart   Restart containers          (e.g. ./deploy.sh restart server)"
        echo "  recreate  Force-recreate containers   (e.g. ./deploy.sh recreate server)"
        echo "  refresh   Pull + force-recreate       (e.g. ./deploy.sh refresh server)"
        echo "  clean     Remove cached images, fresh pull and start all services"
        echo "  down      Stop and remove containers (volumes kept)"
        echo "  logs      Tail logs                  (e.g. ./deploy.sh logs app)"
        echo "  status    Show running containers"
        echo "  health    Validate service HTTP endpoints"
        echo ""
        exit 1
        ;;
esac
