#!/usr/bin/env bash
# =============================================================================
# HomSwag — one-command deployment
#
# Usage:
#   ./deploy.sh                    # full deploy (pull → build images → up → health)
#   ./deploy.sh deploy app         # deploy only one service (server|admin|app)
#   ./deploy.sh --env local deploy app
#   ./deploy.sh --env prod deploy
#   ./deploy.sh --remote deploy    # pull prebuilt images instead of building
#   ./deploy.sh --no-cache build   # pass --no-cache to compose build
#   ./deploy.sh pull               # git pull only
#   ./deploy.sh build              # image build only  (requires repos already pulled)
#   ./deploy.sh up                 # compose up only   (requires images already built)
#   ./deploy.sh restart            # restart containers (no rebuild)
#   ./deploy.sh logs               # tail compose logs
#   ./deploy.sh status             # show running containers
#   ./deploy.sh health             # validate all services are healthy
#   ./deploy.sh down               # stop all containers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colour helpers (defined first — used throughout) ──────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔${NC}  $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC}  $*"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘${NC}  $*" >&2; exit 1; }

# ── Global options ────────────────────────────────────────────────────────────
ENV_PROFILE="${DEPLOY_ENV:-local}"
REMOTE_MODE=false   # when true: pull prebuilt images from registry instead of building
NO_CACHE=false      # when true: pass --no-cache to compose build

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -e|--env)
            [[ "$#" -ge 2 ]] || die "Missing value for $1 (expected: local|prod)"
            ENV_PROFILE="$2"
            shift 2
            ;;
        -r|--remote)
            REMOTE_MODE=true
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

case "$ENV_PROFILE" in
    local)           ENV_FILE=".env.local" ;;
    prod|production) ENV_FILE=".env.prod"  ;;
    *)               die "Invalid env profile '$ENV_PROFILE'. Use: local | prod" ;;
esac

# Export early so compose.yaml and any manual compose calls pick it up.
export DEPLOY_ENV_FILE="$ENV_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ "$ENV_PROFILE" == "local" && -f .env ]]; then
        warn "$ENV_FILE not found, falling back to .env"
        ENV_FILE=".env"
    else
        die "$ENV_FILE not found. Create it first."
    fi
fi

# ── Load selected env file ────────────────────────────────────────────────────
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Only process VAR=value lines
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        # Strip inline comments (everything after ' #' or '  #')
        line="${line%%  #*}"
        line="${line%% #*}"
        export "$line"
    fi
done < "$ENV_FILE"

# ── Discover compose binary ───────────────────────────────────────────────────
if command -v podman &>/dev/null; then
    COMPOSE_BIN="podman compose"
elif command -v docker &>/dev/null; then
    warn "podman not found, falling back to docker compose"
    COMPOSE_BIN="docker compose"
else
    die "Neither podman nor docker found. Please install one of them."
fi

COMPOSE="$COMPOSE_BIN --env-file $ENV_FILE -f compose.yaml"
SERVICES=(server admin app)

# ── Validate required variables ───────────────────────────────────────────────
: "${REPO_SERVER:?REPO_SERVER is not set in $ENV_FILE}"
: "${REPO_ADMIN:?REPO_ADMIN is not set in $ENV_FILE}"
: "${REPO_APP:?REPO_APP is not set in $ENV_FILE}"

# ── Helpers ───────────────────────────────────────────────────────────────────
is_valid_service() {
    local svc="$1"
    for valid in "${SERVICES[@]}"; do
        [[ "$svc" == "$valid" ]] && return 0
    done
    return 1
}

resolve_services() {
    # Strip any flags that sneak in after the command name
    local clean=()
    for a in "$@"; do
        [[ "$a" == -* ]] && continue
        clean+=("$a")
    done

    if [[ "${#clean[@]}" -eq 0 ]]; then
        echo "${SERVICES[*]}"
        return
    fi

    local resolved=()
    for svc in "${clean[@]}"; do
        if [[ "$svc" == "all" ]]; then
            echo "${SERVICES[*]}"
            return
        fi
        is_valid_service "$svc" || die "Invalid service '$svc'. Use one of: server admin app all"
        resolved+=("$svc")
    done

    echo "${resolved[*]}"
}

# =============================================================================
# Sub-commands
# =============================================================================

cmd_pull() {
    echo ""
    echo -e "${BOLD}━━━  Step 1 — Git pull repos  ━━━${NC}"

    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    pull_or_clone() {
        local name="$1"
        local url="$2"
        local dir="repos/$name"

        if [[ -d "$dir/.git" ]]; then
            log "Pulling $name ..."
            git -C "$dir" pull --ff-only
        else
            log "Cloning $name ..."
            mkdir -p repos
            git clone "$url" "$dir"
        fi
        ok "$name up-to-date"
    }

    for svc in "${services[@]}"; do
        case "$svc" in
            server) pull_or_clone server "$REPO_SERVER" ;;
            admin)  pull_or_clone admin  "$REPO_ADMIN"  ;;
            app)    pull_or_clone app    "$REPO_APP"    ;;
        esac
    done
}

# Pull prebuilt images from the registry
cmd_pull_images() {
    echo ""
    echo -e "${BOLD}━━━  Step 2 — Pull container images from registry  ━━━${NC}"

    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    log "Pulling images (${services[*]}) from registry ..."
    $COMPOSE pull "${services[@]}"
    ok "Images pulled"
}

cmd_build() {
    echo ""
    echo -e "${BOLD}━━━  Step 2 — Build container images  ━━━${NC}"

    local raw_args=()
    for arg in "$@"; do
        case "$arg" in
            --no-cache) NO_CACHE=true ;;
            *)          raw_args+=("$arg") ;;
        esac
    done

    local services=()
    if [[ "${#raw_args[@]}" -gt 0 ]]; then
        read -r -a services <<< "$(resolve_services "${raw_args[@]}")"
    else
        read -r -a services <<< "$(resolve_services)"
    fi

    for svc in "${services[@]}"; do
        [[ -d "repos/$svc" ]] || die "repos/$svc not found — run './deploy.sh pull' first"
    done

    local build_opts=()
    [[ "$NO_CACHE" == true ]] && build_opts+=(--no-cache)

    log "Building images (${services[*]}) sequentially to avoid OOM ..."
    for svc in "${services[@]}"; do
        $COMPOSE build "${build_opts[@]}" "$svc"
    done
    ok "All images built"
}

cmd_up() {
    echo ""
    echo -e "${BOLD}━━━  Step 3 — Start services  ━━━${NC}"

    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    local with_infra=("${services[@]}")

    # server depends on mongodb, redis and minio
    local include_server_infra=false
    for svc in "${services[@]}"; do
        [[ "$svc" == "server" ]] && include_server_infra=true && break
    done

    if [[ "$include_server_infra" == true ]]; then
        with_infra+=(mongodb redis minio)
    fi

    # Deduplicate while preserving order
    local deduped=()
    local seen=""
    for svc in "${with_infra[@]}"; do
        if [[ " $seen " != *" $svc "* ]]; then
            deduped+=("$svc")
            seen+=" $svc"
        fi
    done

    log "Starting (${deduped[*]}) ..."
    $COMPOSE up -d "${deduped[@]}"
    echo ""
    ok "Containers started:"
    $COMPOSE ps
    echo ""
    echo -e "  ${BOLD}Server${NC}   → http://localhost:3000"
    echo -e "  ${BOLD}Admin${NC}    → http://localhost:3001"
    echo -e "  ${BOLD}App${NC}      → http://localhost:3002"
    echo -e "  ${BOLD}MinIO${NC}    → http://localhost:9001"
    echo -e "  ${BOLD}MongoDB${NC}  → localhost:27017"
    echo ""
}

# ── Health validation ─────────────────────────────────────────────────────────
cmd_health() {
    echo ""
    echo -e "${BOLD}━━━  Step 4 — Health validation  ━━━${NC}"

    local max_wait="${HEALTH_TIMEOUT:-60}"   # seconds; override via HEALTH_TIMEOUT env var
    local interval=3
    local elapsed
    local all_ok=true

    declare -A endpoints=(
        [server]="http://localhost:3000/health"
        [admin]="http://localhost:3001"
        [app]="http://localhost:3002"
    )

    for svc in server admin app; do
        local url="${endpoints[$svc]}"
        local svc_ok=false
        elapsed=0

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
        die "One or more services failed health checks. Run './deploy.sh logs' to investigate."
    fi
}

cmd_deploy() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      HomSwag — Full Deploy           ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"

    cmd_pull "$@"

    if [[ "$REMOTE_MODE" == true ]]; then
        cmd_pull_images "$@"
    else
        cmd_build "$@"
    fi

    cmd_up "$@"
    cmd_health
}

cmd_restart() {
    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    log "Restarting (${services[*]}) ..."
    $COMPOSE restart "${services[@]}"
    ok "Done"
    $COMPOSE ps
}

cmd_down() {
    warn "Stopping all containers (data volumes preserved) ..."
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
shift || true   # consume the command; remaining args forwarded to sub-commands

# Strip any global flags that appear after the command name
if [[ "$#" -gt 0 ]]; then
    local_kept=()
    for arg in "$@"; do
        case "$arg" in
            -r|--remote)  REMOTE_MODE=true ;;
            --no-cache)   NO_CACHE=true    ;;
            *)            local_kept+=("$arg") ;;
        esac
    done
    if [[ "${#local_kept[@]}" -gt 0 ]]; then
        set -- "${local_kept[@]}"
    else
        set --
    fi
fi

case "$COMMAND" in
    deploy|"")  cmd_deploy  "$@" ;;
    pull)       cmd_pull    "$@" ;;
    build)      cmd_build   "$@" ;;
    up)         cmd_up      "$@" ;;
    restart)    cmd_restart "$@" ;;
    down)       cmd_down        ;;
    logs)       cmd_logs    "$@" ;;
    status)     cmd_status      ;;
    health)     cmd_health      ;;
    *)
        echo "Usage: $0 [--env local|prod] [--remote] [--no-cache]"
        echo "       [deploy|pull|build|up|restart|logs|status|health|down]"
        echo "       [server|admin|app|all]"
        exit 1
        ;;
esac
