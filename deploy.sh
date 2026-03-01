#!/usr/bin/env bash
# =============================================================================
# HomSwag — one-command deployment
#
# Usage:
#   ./deploy.sh              # full deploy (pull → build images → compose up)
#   ./deploy.sh deploy app   # deploy only one service (server|admin|app)
#   ./deploy.sh --env local deploy app
#   ./deploy.sh --env prod deploy
#   ./deploy.sh pull         # git pull only
#   ./deploy.sh build        # image build only  (requires repos already pulled)
#   ./deploy.sh up           # compose up only   (requires images already built)
#   ./deploy.sh restart      # compose down + up (no rebuild)
#   ./deploy.sh logs         # tail compose logs
#   ./deploy.sh status       # show running containers
#   ./deploy.sh down         # stop all containers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Global options (must come before command) ───────────────────────────────
# Examples:
#   ./deploy.sh --env local deploy app
#   ./deploy.sh -e prod up admin
ENV_PROFILE="${DEPLOY_ENV:-local}"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -e|--env)
            [[ "$#" -ge 2 ]] || die "Missing value for $1 (expected: local|prod)"
            ENV_PROFILE="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

case "$ENV_PROFILE" in
    local) ENV_FILE=".env.local" ;;
    prod|production) ENV_FILE=".env.prod" ;;
    *) die "Invalid env profile '$ENV_PROFILE'. Use: local | prod" ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ "$ENV_PROFILE" == "local" && -f .env ]]; then
        warn "$ENV_FILE not found, falling back to .env"
        ENV_FILE=".env"
    else
        die "$ENV_FILE not found. Create it first."
    fi
fi

# ── Colour helpers ────────────────────────────────────────────────────────────
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

# ── Load selected env file ───────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # Parse manually to handle comments, blank lines and inline comments safely
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and lines starting with #
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Only process lines that look like VAR=value
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            # Strip inline comments (everything after  ' #' or ' # ')
            line="${line%%  #*}"
            line="${line%% #*}"
            export "$line"
        fi
    done < "$ENV_FILE"
else
    die "$ENV_FILE not found."
fi

# ── Discover compose binary ───────────────────────────────────────────────────
if command -v podman &>/dev/null; then
    COMPOSE_BIN="podman compose"
elif command -v docker &>/dev/null; then
    warn "podman not found, falling back to docker compose"
    COMPOSE_BIN="docker compose"
else
    die "Neither podman nor docker found. Please install podman."
fi

export DEPLOY_ENV_FILE="$ENV_FILE"
COMPOSE="$COMPOSE_BIN --env-file $ENV_FILE -f compose.yaml"
SERVICES=(server admin app)

# ── Validate required variables ───────────────────────────────────────────────
: "${REPO_SERVER:?REPO_SERVER is not set in .env}"
: "${REPO_ADMIN:?REPO_ADMIN is not set in .env}"
: "${REPO_APP:?REPO_APP is not set in .env}"

is_valid_service() {
    local svc="$1"
    for valid in "${SERVICES[@]}"; do
        [[ "$svc" == "$valid" ]] && return 0
    done
    return 1
}

resolve_services() {
    if [[ "$#" -eq 0 ]]; then
        echo "${SERVICES[*]}"
        return
    fi

    local resolved=()
    for svc in "$@"; do
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
    echo -e "${BOLD}━━━  Step 1 / 3 — Git pull repos  ━━━${NC}"

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
            admin)  pull_or_clone admin  "$REPO_ADMIN" ;;
            app)    pull_or_clone app    "$REPO_APP" ;;
        esac
    done
}

cmd_build() {
    echo ""
    echo -e "${BOLD}━━━  Step 2 / 3 — Build container images  ━━━${NC}"

    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    for svc in "${services[@]}"; do
        [[ -d "repos/$svc" ]] || die "repos/$svc not found — run './deploy.sh pull' first"
    done

    log "Building images (${services[*]}) — sequentially to avoid OOM ..."
    for svc in "${services[@]}"; do
        $COMPOSE build "$svc"
    done
    ok "All images built"
}

cmd_up() {
    echo ""
    echo -e "${BOLD}━━━  Step 3 / 3 — Start services  ━━━${NC}"

    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    local with_infra=()
    with_infra=("${services[@]}")

    # Ensure required infra exists for app services.
    # server requires mongodb + redis and typically minio for media storage.
    local include_server_infra=false
    for svc in "${services[@]}"; do
        if [[ "$svc" == "server" ]]; then
            include_server_infra=true
            break
        fi
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

    log "Starting services (${deduped[*]}) and required dependencies ..."
    $COMPOSE up -d "${deduped[@]}"
    echo ""
    ok "All containers running:"
    $COMPOSE ps
    echo ""
    echo -e "  ${BOLD}Server${NC}   → http://localhost:3000"
    echo -e "  ${BOLD}Admin${NC}    → http://localhost:3001"
    echo -e "  ${BOLD}App${NC}      → http://localhost:3002"
    echo -e "  ${BOLD}MinIO${NC}    → http://localhost:9001"
    echo -e "  ${BOLD}MongoDB${NC}  → localhost:27017"
    echo ""
}

cmd_deploy() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      HomSwag — Full Deploy           ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    cmd_pull "$@"
    cmd_build "$@"
    cmd_up "$@"
}

cmd_restart() {
    local services=()
    read -r -a services <<< "$(resolve_services "$@")"

    log "Restarting application containers (${services[*]}) ..."
    $COMPOSE restart "${services[@]}"
    ok "Done"
    $COMPOSE ps
}

cmd_down() {
    warn "Stopping all containers (data volumes are preserved) ..."
    $COMPOSE down || true
    ok "All containers stopped"
}

cmd_logs() {
    $COMPOSE logs -f --tail=100 "${@:-}"
}

cmd_status() {
    $COMPOSE ps
}

# =============================================================================
# Entrypoint
# =============================================================================
COMMAND="${1:-deploy}"
shift || true   # consume first arg; remaining args forwarded where needed

case "$COMMAND" in
    deploy|"")  cmd_deploy "$@"  ;;
    pull)       cmd_pull "$@"    ;;
    build)      cmd_build "$@"   ;;
    up)         cmd_up "$@"      ;;
    restart)    cmd_restart "$@" ;;
    down)       cmd_down    ;;
    logs)       cmd_logs "$@" ;;
    status)     cmd_status  ;;
    *)
        echo "Usage: $0 [--env local|prod] [deploy|pull|build|up|restart|logs|status|down] [server|admin|app|all]"
        exit 1
        ;;
esac
