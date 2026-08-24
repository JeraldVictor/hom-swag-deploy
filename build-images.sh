#!/usr/bin/env bash
# =============================================================================
# HomSwag - Build deployment images
#
# Usage:
#   ./build-images.sh                         # build production deployment images locally
#   ./build-images.sh --push                  # build production deployment images and push to GHCR
#   ./build-images.sh --env prod --push       # read tags/build args from .env.prod
#   ./build-images.sh --env prod --no-cache --push # clean rebuild production images and push
#   ./build-images.sh --tag 2026.06.15 --push # use one tag for all services
#   ./build-images.sh server admin            # build selected services
#   ./build-images.sh --image-registry ghcr.io/owner --push-registry ghcr.io/owner
#
# Services: server, reporting, admin, app, mobile, partner
# Builds/tags local images under IMAGE_REGISTRY. Only --push tags and pushes
# the matching image to PUSH_REGISTRY.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] \u2714${NC}  $*" >&2; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] \u26a0${NC}  $*" >&2; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] \u2718${NC}  $*" >&2; exit 1; }

IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/jeraldvictor}"
PUSH_REGISTRY="${PUSH_REGISTRY:-ghcr.io/jeraldvictor}"
PUSH_REGISTRY_EXPLICIT=false
ENV_PROFILE="${DEPLOY_ENV:-prod}"
ENV_FILE=""
TAG_OVERRIDE=""
PUSH=false
NO_CACHE=false
PLATFORM="${BUILD_PLATFORM:-linux/amd64}"
SERVICES=()

is_service() {
    case "$1" in
        server|reporting|admin|app|mobile|partner|all) return 0 ;;
        *) return 1 ;;
    esac
}

is_infra_service() {
    case "$1" in
        mongodb|redis|minio|mongo-express) return 0 ;;
        *) return 1 ;;
    esac
}

is_ghcr_push_registry() {
    [[ "${PUSH_REGISTRY:-}" == ghcr.io/* ]]
}

ensure_push_registry_auth() {
    if [[ "$PUSH" != true ]] || ! is_ghcr_push_registry; then
        return
    fi

    warn "GHCR pushes require Docker to be logged in to ghcr.io with a token that can write packages"
    warn "Use: echo '<github-token>' | docker login ghcr.io -u '<github-user>' --password-stdin"
}

is_prod_profile() {
    [[ "$ENV_PROFILE" == "prod" || "$ENV_PROFILE" == "production" ]]
}

is_local_url() {
    local value="${1:-}"
    [[ "$value" =~ ^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)(:|/|$) ]]
}

require_prod_url() {
    local name="$1"
    local value="${2:-}"
    if ! is_prod_profile; then
        return
    fi
    [[ -n "$value" ]] || die "$name is required for production image builds"
    if is_local_url "$value"; then
        die "$name resolves to local URL '$value' during a production image build"
    fi
}

frontend_api_url() {
    local api_url="${VITE_API_BASE_URL:-}"
    if ! is_prod_profile; then
        api_url="${api_url:-http://localhost:${SERVER_PORT:-3000}}"
    fi
    echo "$api_url"
}

frontend_login_url() {
    local api_url
    api_url="$(frontend_api_url)"
    local login_url="${VITE_AUTH_API_BASE_URL:-$api_url}"
    if ! is_prod_profile; then
        login_url="${login_url:-$api_url}"
    fi
    echo "$login_url"
}

frontend_media_url() {
    local api_url
    api_url="$(frontend_api_url)"
    local media_url="${VITE_MEDIA_BASE_URL:-${MEDIA_BASE_URL:-$api_url}}"
    if ! is_prod_profile; then
        media_url="${media_url:-$api_url}"
    fi
    echo "$media_url"
}

frontend_bff_url() {
    local bff_url="${VITE_BFF_BASE_URL:-${BFF_BASE_URL:-}}"
    if [[ -z "$bff_url" && -n "${VITE_API_BASE_URL:-}" ]]; then
        bff_url="${VITE_API_BASE_URL%/}/bff"
    fi
    if ! is_prod_profile; then
        bff_url="${bff_url:-http://localhost:${SERVER_PORT:-3000}/bff}"
    fi
    echo "$bff_url"
}

server_bff_url() {
    local bff_url="${BFF_BASE_URL:-}"
    if [[ -z "$bff_url" ]]; then
        if is_prod_profile; then
            bff_url="$(frontend_bff_url)"
        else
            bff_url="http://server:${SERVER_PORT:-3000}/bff"
        fi
    fi
    echo "$bff_url"
}

frontend_reporting_url() {
    local reporting_url="${HS_REPORTING_URL:-${VITE_REPORTING_BASE_URL:-}}"
    if ! is_prod_profile; then
        reporting_url="${reporting_url:-${VITE_API_BASE_URL:-http://localhost:${SERVER_PORT:-3000}}}"
    fi
    echo "$reporting_url"
}

partner_bff_api_url() {
    local bff_api_url="${VITE_PARTNER_BFF_API_URL:-${VITE_BFF_API_URL:-}}"
    if [[ -z "${VITE_PARTNER_BFF_API_URL:-}" && "$bff_api_url" == */bff ]]; then
        bff_api_url="${bff_api_url%/}/field"
    fi
    if [[ -z "$bff_api_url" && -n "${VITE_API_BASE_URL:-}" ]]; then
        bff_api_url="${VITE_API_BASE_URL%/}/bff/field"
    fi
    if ! is_prod_profile; then
        bff_api_url="${bff_api_url:-http://localhost:${SERVER_PORT:-3000}/bff/field}"
    fi
    echo "$bff_api_url"
}

partner_bff_base_url() {
    local bff_base_url="${VITE_PARTNER_BFF_BASE_URL:-${VITE_BFF_BASE_URL:-${BFF_BASE_URL:-}}}"
    if [[ -z "$bff_base_url" && -n "${VITE_API_BASE_URL:-}" ]]; then
        bff_base_url="${VITE_API_BASE_URL%/}"
    fi
    if ! is_prod_profile; then
        bff_base_url="${bff_base_url:-http://localhost:${SERVER_PORT:-3000}}"
    fi
    echo "$bff_base_url"
}

partner_ws_url() {
    local ws_url="${VITE_PARTNER_WS_URL:-${VITE_WS_URL:-}}"
    if [[ -z "$ws_url" && -n "${VITE_API_BASE_URL:-}" ]]; then
        ws_url="${VITE_API_BASE_URL/https:/wss:}"
        ws_url="${ws_url/http:/ws:}"
    fi
    if ! is_prod_profile; then
        ws_url="${ws_url:-http://localhost:${SERVER_PORT:-3000}}"
    fi
    echo "$ws_url"
}

admin_utility_url() {
    local variable_name="$1"
    local local_default="$2"
    local prod_default="$3"
    local value="${!variable_name:-}"

    if [[ -n "$value" ]]; then
        echo "$value"
    elif is_prod_profile; then
        echo "$prod_default"
    else
        echo "$local_default"
    fi
}

print_resolved_env() {
    local api_url login_url media_url bff_url server_bff reporting_url customer_app_url partner_api_url partner_ws
    local partner_app_url signoz_url portainer_url monitor_url
    api_url="$(frontend_api_url)"
    login_url="$(frontend_login_url)"
    media_url="$(frontend_media_url)"
    bff_url="$(frontend_bff_url)"
    server_bff="$(server_bff_url)"
    reporting_url="$(frontend_reporting_url)"
    customer_app_url="${VITE_CUSTOMER_APP_URL:-}"
    partner_api_url="$(partner_bff_api_url)"
    partner_ws="$(partner_ws_url)"
    partner_app_url="$(admin_utility_url VITE_PARTNER_APP_URL http://localhost:8090 https://partner.homswag.com)"
    signoz_url="$(admin_utility_url VITE_SIGNOZ_URL http://localhost:9080 https://signoz.homswag.com)"
    portainer_url="$(admin_utility_url VITE_PORTAINER_URL https://localhost:9443 https://ports.homswag.com)"
    monitor_url="$(admin_utility_url VITE_MONITOR_URL http://localhost:14318 https://monitor.homswag.com)"

    require_prod_url VITE_API_BASE_URL "$api_url"
    require_prod_url VITE_AUTH_API_BASE_URL "$login_url"
    require_prod_url VITE_MEDIA_BASE_URL "$media_url"
    require_prod_url VITE_BFF_BASE_URL "$bff_url"
    require_prod_url VITE_REPORTING_BASE_URL "$reporting_url"
    require_prod_url VITE_REPORTING_SERVICE_URL "$reporting_url"
    require_prod_url VITE_CUSTOMER_APP_URL "$customer_app_url"
    require_prod_url VITE_PARTNER_APP_URL "$partner_app_url"
    require_prod_url VITE_SIGNOZ_URL "$signoz_url"
    require_prod_url VITE_PORTAINER_URL "$portainer_url"
    require_prod_url VITE_MONITOR_URL "$monitor_url"
    require_prod_url VITE_PARTNER_BFF_API_URL "$partner_api_url"
    require_prod_url VITE_PARTNER_WS_URL "$partner_ws"

    echo -e "${BOLD}Resolved build env:${NC}"
    echo -e "  NODE_ENV              : ${BOLD}${NODE_ENV:-unset}${NC}"
    echo -e "  APP_URL               : ${BOLD}${APP_URL:-unset}${NC}"
    echo -e "  VITE_API_BASE_URL     : ${BOLD}${api_url}${NC}"
    echo -e "  VITE_AUTH_API_BASE_URL: ${BOLD}${login_url}${NC}"
    echo -e "  VITE_MEDIA_BASE_URL   : ${BOLD}${media_url}${NC}"
    echo -e "  VITE_BFF_BASE_URL     : ${BOLD}${bff_url}${NC}"
    echo -e "  BFF_BASE_URL          : ${BOLD}${server_bff}${NC}"
    echo -e "  VITE_REPORTING_BASE_URL: ${BOLD}${reporting_url}${NC}"
    echo -e "  VITE_REPORTING_SERVICE_URL: ${BOLD}${reporting_url}${NC}"
    echo -e "  VITE_REPORTING_API_TOKEN: ${BOLD}$([[ -n "${VITE_REPORTING_API_TOKEN:-${REPORTING_API_TOKEN:-}}" ]] && echo set || echo unset)${NC}"
    echo -e "  VITE_CUSTOMER_APP_URL : ${BOLD}${customer_app_url:-unset}${NC}"
    echo -e "  VITE_PARTNER_APP_URL  : ${BOLD}${partner_app_url}${NC}"
    echo -e "  VITE_SIGNOZ_URL       : ${BOLD}${signoz_url}${NC}"
    echo -e "  VITE_PORTAINER_URL    : ${BOLD}${portainer_url}${NC}"
    echo -e "  VITE_MONITOR_URL      : ${BOLD}${monitor_url}${NC}"
    echo -e "  VITE_PARTNER_BFF_API_URL: ${BOLD}${partner_api_url}${NC}"
    echo -e "  VITE_PARTNER_WS_URL   : ${BOLD}${partner_ws}${NC}"
    echo -e "  SERVER_IMAGE_TAG      : ${BOLD}${SERVER_IMAGE_TAG:-latest}${NC}"
    echo -e "  REPORTING_IMAGE_TAG   : ${BOLD}${REPORTING_IMAGE_TAG:-latest}${NC}"
    echo -e "  ADMIN_IMAGE_TAG       : ${BOLD}${ADMIN_IMAGE_TAG:-latest}${NC}"
    echo -e "  APP_IMAGE_TAG         : ${BOLD}${APP_IMAGE_TAG:-latest}${NC}"
    echo -e "  MOBILE_IMAGE_TAG      : ${BOLD}${MOBILE_IMAGE_TAG:-latest}${NC}"
    echo -e "  PARTNER_IMAGE_TAG     : ${BOLD}${PARTNER_IMAGE_TAG:-latest}${NC}"
    echo -e "  NO_CACHE              : ${BOLD}${NO_CACHE}${NC}"
    echo ""
}

services_include() {
    local needle="$1"
    local service
    for service in "${SERVICES[@]}"; do
        if [[ "$service" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

reporting_integration_mongodb_uri() {
    if [[ -n "${REPORTING_INTEGRATION_MONGODB_URI:-}" ]]; then
        echo "$REPORTING_INTEGRATION_MONGODB_URI"
        return
    fi
    if [[ -n "${REPORTING_BUILD_TEST_MONGODB_URI:-}" ]]; then
        echo "$REPORTING_BUILD_TEST_MONGODB_URI"
        return
    fi
    if ! is_prod_profile; then
        local mongo_user="${MONGO_USER:-admin}"
        local mongo_password="${MONGO_PASSWORD:-password}"
        local mongo_host_port="${MONGO_HOST_PORT:-${MONGO_PORT:-27017}}"
        echo "mongodb://${mongo_user}:${mongo_password}@127.0.0.1:${mongo_host_port}/admin?authSource=admin"
    fi
}

run_reporting_test_gate() {
    if ! services_include reporting; then
        return
    fi
    local reporting_source
    reporting_source="$(require_source reporting)"
    local reporting_test_gocache="${REPORTING_TEST_GOCACHE:-$reporting_source/.gocache}"
    mkdir -p "$reporting_test_gocache"

    command -v go &>/dev/null || die "go is required to build the reporting image because tests must pass before image build"

    echo ""
    echo -e "${BOLD}━━━  Testing reporting before image build  ━━━${NC}"
    log "Source: $reporting_source"

    log "Running reporting Go unit suite"
    (cd "$reporting_source" && GOCACHE="$reporting_test_gocache" go test ./...)
    ok "Reporting Go unit suite passed"

    local integration_uri
    integration_uri="$(reporting_integration_mongodb_uri)"
    if [[ -z "$integration_uri" ]]; then
        die "REPORTING_BUILD_TEST_MONGODB_URI or REPORTING_INTEGRATION_MONGODB_URI is required for production reporting image builds. Use a staging/test MongoDB URI, not production."
    fi

    log "Running reporting Mongo aggregation integration suite"
    (
        cd "$reporting_source"
        GOCACHE="$reporting_test_gocache" REPORTING_INTEGRATION_MONGODB_URI="$integration_uri" go test ./internal/reports/static -run MongoIntegration -count=1
    )
    ok "Reporting Mongo aggregation integration suite passed"
}

has_test_files() {
    local source="$1"
    rg --files "$source" \
        | rg -q '(/|^)(__tests__|tests?)/|\.spec\.[jt]sx?$|\.spec\.[cm]?jsx?$|\.test\.[jt]sx?$|\.test\.[cm]?jsx?$'
}

npm_script_exists() {
    local source="$1"
    local script_name="$2"
    [[ -f "$source/package.json" ]] || return 1
    rg -q "\"${script_name}\"[[:space:]]*:" "$source/package.json"
}

run_node_test_gate() {
    local service="$1"
    local source="$2"
    local test_cmd=()

    if ! has_test_files "$source"; then
        warn "Skipping ${service} tests: no test files detected"
        return
    fi

    command -v pnpm &>/dev/null || die "pnpm is required to run ${service} tests before image build"

    if npm_script_exists "$source" "test"; then
        test_cmd=(pnpm test)
    elif npm_script_exists "$source" "test:unit"; then
        test_cmd=(pnpm test:unit)
    elif rg -q '"vitest"' "$source/package.json"; then
        test_cmd=(pnpm exec vitest run)
    else
        warn "Skipping ${service} tests: package has tests but no known runnable test command"
        return
    fi

    echo ""
    echo -e "${BOLD}━━━  Testing ${service} before image build  ━━━${NC}"
    log "Source: $source"
    log "Command: ${test_cmd[*]}"
    (cd "$source" && "${test_cmd[@]}")
    ok "${service} test suite passed"
}

run_test_gate_for_service() {
    local service="$1"

    case "$service" in
        server|admin|app|mobile|partner)
            run_node_test_gate "$service" "$(require_source "$service")"
            ;;
        reporting)
            run_reporting_test_gate
            ;;
        *)
            warn "No test gate configured for ${service}; skipping"
            ;;
    esac
}

write_frontend_env_files() {
    local service="$1"
    local target_dir="$2"

    case "$service" in
        app)
        local api_url login_url media_url bff_url server_bff
            api_url="$(frontend_api_url)"
            login_url="$(frontend_login_url)"
            media_url="$(frontend_media_url)"
            bff_url="$(frontend_bff_url)"
            server_bff="$(server_bff_url)"

            require_prod_url VITE_API_BASE_URL "$api_url"
            require_prod_url VITE_AUTH_API_BASE_URL "$login_url"
            require_prod_url VITE_MEDIA_BASE_URL "$media_url"
            require_prod_url VITE_BFF_BASE_URL "$bff_url"

            cat > "$target_dir/.env.prod" <<EOF
VITE_API_BASE_URL=$api_url
VITE_AUTH_API_BASE_URL=$login_url
VITE_MEDIA_BASE_URL=$media_url
VITE_ENABLE_RUM=${VITE_ENABLE_RUM:-false}
VITE_RUM_TRACES_ENDPOINT=${VITE_RUM_TRACES_ENDPOINT:-}
VITE_RUM_SERVICE_NAME=${VITE_APP_RUM_SERVICE_NAME:-customer-app}
VITE_DEPLOYMENT_ENVIRONMENT=${VITE_DEPLOYMENT_ENVIRONMENT:-${DEPLOYMENT_ENVIRONMENT:-production}}
PUBLIC_API_BASE_URL=$api_url
MEDIA_BASE_URL=$media_url
BFF_BASE_URL=$server_bff
VITE_BFF_BASE_URL=$bff_url
EOF
            cp "$target_dir/.env.prod" "$target_dir/.env.production"
            ;;
        mobile)
            local api_url media_url bff_url ws_url
            api_url="$(frontend_api_url)"
            media_url="$(frontend_media_url)"
            bff_url="$(frontend_bff_url)"
            ws_url="${VITE_WS_URL:-}"
            if [[ -z "$ws_url" ]]; then
                ws_url="${api_url/https:/wss:}"
                ws_url="${ws_url/http:/ws:}"
            fi

            require_prod_url VITE_API_BASE_URL "$api_url"
            require_prod_url VITE_MEDIA_BASE_URL "$media_url"
            require_prod_url VITE_BFF_BASE_URL "$bff_url"
            require_prod_url VITE_WS_URL "$ws_url"

            cat > "$target_dir/.env.prod" <<EOF
VITE_API_BASE_URL=$api_url
VITE_AUTH_API_BASE_URL=$api_url
VITE_BFF_API_URL=$bff_url
VITE_BFF_BASE_URL=$bff_url
VITE_MEDIA_BASE_URL=$media_url
VITE_WS_URL=$ws_url
VITE_GOOGLE_MAPS_API_KEY=${VITE_GOOGLE_MAPS_API_KEY:-}
VITE_FEATURE_MAPS=${VITE_FEATURE_MAPS:-true}
VITE_FEATURE_DIRECTIONS=${VITE_FEATURE_DIRECTIONS:-true}
EOF
            cp "$target_dir/.env.prod" "$target_dir/.env.production"
            ;;
        admin)
            local api_url login_url media_url reporting_url
            local customer_app_url partner_app_url signoz_url portainer_url monitor_url
            api_url="$(frontend_api_url)"
            login_url="$(frontend_login_url)"
            media_url="$(frontend_media_url)"
            reporting_url="$(frontend_reporting_url)"
            customer_app_url="${VITE_CUSTOMER_APP_URL:-}"
            partner_app_url="$(admin_utility_url VITE_PARTNER_APP_URL http://localhost:8090 https://partner.homswag.com)"
            signoz_url="$(admin_utility_url VITE_SIGNOZ_URL http://localhost:9080 https://signoz.homswag.com)"
            portainer_url="$(admin_utility_url VITE_PORTAINER_URL https://localhost:9443 https://ports.homswag.com)"
            monitor_url="$(admin_utility_url VITE_MONITOR_URL http://localhost:14318 https://monitor.homswag.com)"

            require_prod_url VITE_API_BASE_URL "$api_url"
            require_prod_url VITE_AUTH_API_BASE_URL "$login_url"
            require_prod_url VITE_MEDIA_BASE_URL "$media_url"
            require_prod_url VITE_REPORTING_BASE_URL "$reporting_url"
            require_prod_url VITE_CUSTOMER_APP_URL "$customer_app_url"
            require_prod_url VITE_PARTNER_APP_URL "$partner_app_url"
            require_prod_url VITE_SIGNOZ_URL "$signoz_url"
            require_prod_url VITE_PORTAINER_URL "$portainer_url"
            require_prod_url VITE_MONITOR_URL "$monitor_url"

            cat > "$target_dir/.env.prod" <<EOF
VITE_API_BASE_URL=$api_url
VITE_AUTH_API_BASE_URL=$login_url
VITE_MEDIA_BASE_URL=$media_url
VITE_REPORTING_BASE_URL=$reporting_url
VITE_REPORTING_SERVICE_URL=$reporting_url
VITE_REPORTING_API_TOKEN=${VITE_REPORTING_API_TOKEN:-${REPORTING_API_TOKEN:-}}
VITE_ENABLE_RUM=${VITE_ENABLE_RUM:-false}
VITE_RUM_TRACES_ENDPOINT=${VITE_RUM_TRACES_ENDPOINT:-}
VITE_RUM_SERVICE_NAME=${VITE_ADMIN_RUM_SERVICE_NAME:-admin-app}
VITE_DEPLOYMENT_ENVIRONMENT=${VITE_DEPLOYMENT_ENVIRONMENT:-${DEPLOYMENT_ENVIRONMENT:-production}}
PUBLIC_API_BASE_URL=$api_url
MEDIA_BASE_URL=$media_url
VITE_CUSTOMER_APP_URL=$customer_app_url
VITE_PARTNER_APP_URL=$partner_app_url
VITE_SIGNOZ_URL=$signoz_url
VITE_PORTAINER_URL=$portainer_url
VITE_MONITOR_URL=$monitor_url
EOF
            cp "$target_dir/.env.prod" "$target_dir/.env.production"
            ;;
        partner)
            local bff_api_url bff_base_url media_url ws_url
            bff_api_url="$(partner_bff_api_url)"
            bff_base_url="$(partner_bff_base_url)"
            media_url="$(frontend_media_url)"
            ws_url="$(partner_ws_url)"

            require_prod_url VITE_PARTNER_BFF_API_URL "$bff_api_url"
            require_prod_url VITE_PARTNER_BFF_BASE_URL "$bff_base_url"
            require_prod_url VITE_MEDIA_BASE_URL "$media_url"
            require_prod_url VITE_PARTNER_WS_URL "$ws_url"

            cat > "$target_dir/.env.prod" <<EOF
VITE_BFF_API_URL=$bff_api_url
VITE_BFF_BASE_URL=$bff_base_url
VITE_MEDIA_BASE_URL=$media_url
VITE_WS_URL=$ws_url
VITE_GOOGLE_MAPS_API_KEY=${VITE_GOOGLE_MAPS_API_KEY:-}
VITE_FEATURE_MAPS=${VITE_FEATURE_MAPS:-false}
VITE_FEATURE_DIRECTIONS=${VITE_FEATURE_DIRECTIONS:-false}
EOF
            cp "$target_dir/.env.prod" "$target_dir/.env.production"
            ;;
        server)
            if is_prod_profile; then
                cat > "$target_dir/.env.prod" <<EOF
NODE_ENV=${NODE_ENV:-production}
PORT=${PORT:-3000}
HOST=${HOST:-0.0.0.0}
APP_URL=${APP_URL:-}
CORS_ALLOWED_ORIGINS=${CORS_ALLOWED_ORIGINS:-}
ENABLE_SWAGGER=${ENABLE_SWAGGER:-false}
ERROR_INCLUDE_STACK=${ERROR_INCLUDE_STACK:-false}
EOF
            fi
            ;;
    esac
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -e|--env)
            [[ "$#" -ge 2 ]] || die "Missing value for $1 (expected: local|prod)"
            ENV_PROFILE="$2"
            shift 2
            ;;
        --env=*)
            ENV_PROFILE="${1#*=}"
            shift
            ;;
        --env-file)
            [[ "$#" -ge 2 ]] || die "Missing value for --env-file"
            ENV_FILE="$2"
            shift 2
            ;;
        --env-file=*)
            ENV_FILE="${1#*=}"
            shift
            ;;
        --image-registry)
            [[ "$#" -ge 2 ]] || die "Missing value for --image-registry"
            IMAGE_REGISTRY="${2%/}"
            shift 2
            ;;
        --image-registry=*)
            IMAGE_REGISTRY="${1#*=}"
            IMAGE_REGISTRY="${IMAGE_REGISTRY%/}"
            shift
            ;;
        --push-registry|--registry)
            [[ "$#" -ge 2 ]] || die "Missing value for --registry"
            PUSH_REGISTRY="${2%/}"
            PUSH_REGISTRY_EXPLICIT=true
            shift 2
            ;;
        --push-registry=*|--registry=*)
            PUSH_REGISTRY="${1#*=}"
            PUSH_REGISTRY="${PUSH_REGISTRY%/}"
            PUSH_REGISTRY_EXPLICIT=true
            shift
            ;;
        --tag|-t)
            [[ "$#" -ge 2 ]] || die "Missing value for $1"
            TAG_OVERRIDE="$2"
            shift 2
            ;;
        --tag=*)
            TAG_OVERRIDE="${1#*=}"
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --platform)
            [[ "$#" -ge 2 ]] || die "Missing value for --platform"
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        -h|--help)
            sed -n '1,22p' "$SCRIPT_DIR/$(basename "$0")"
            exit 0
            ;;
        *)
            if is_service "$1"; then
                if [[ "$1" == "all" ]]; then
                    SERVICES=(server reporting admin app mobile partner)
                else
                    SERVICES+=("$1")
                fi
                shift
            elif is_infra_service "$1"; then
                die "$1 is an infrastructure image. Pull/deploy it with ./deploy.sh --env ${ENV_PROFILE} pull $1 or ./deploy.sh --env ${ENV_PROFILE} up $1."
            else
                die "Unknown argument '$1'. Use --help for usage."
            fi
            ;;
    esac
done

if [[ -z "$ENV_FILE" ]]; then
    case "$ENV_PROFILE" in
        local)           ENV_FILE=".env.local" ;;
        prod|production) ENV_FILE=".env.prod" ;;
        *)               die "Invalid env profile '$ENV_PROFILE'. Use: local | prod" ;;
    esac
fi

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Create it before building."

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        line="${line%%  #*}"; line="${line%% #*}"
        export "$line"
    fi
done < "$ENV_FILE"

if [[ "$PUSH" == true ]] && ! is_prod_profile; then
    die "Refusing to push non-production images. Use --env prod --push for registry pushes."
fi

if [[ "$PUSH" == true && "$ENV_FILE" != ".env.prod" ]]; then
    die "Refusing to push with env file '$ENV_FILE'. Registry pushes must use .env.prod."
fi

if [[ "$PUSH_REGISTRY_EXPLICIT" == false ]]; then
    PUSH_REGISTRY="${PUSH_REGISTRY:-ghcr.io/jeraldvictor}"
fi
IMAGE_REGISTRY="${IMAGE_REGISTRY%/}"
PUSH_REGISTRY="${PUSH_REGISTRY%/}"

if [[ "${#SERVICES[@]}" -eq 0 ]]; then
    SERVICES=(server reporting admin app mobile partner)
fi

if command -v docker &>/dev/null; then
    CONTAINER_BIN="docker"
elif command -v podman &>/dev/null; then
    warn "docker not found - falling back to podman"
    CONTAINER_BIN="podman"
else
    die "Neither docker nor podman found. Please install one of them."
fi

require_source() {
    local service="$1"
    local deploy_repo="$SCRIPT_DIR/repos/$service"
    local workspace_repo="$WORKSPACE_DIR/$service"

    if [[ "$service" == "partner" ]]; then
        deploy_repo="$SCRIPT_DIR/repos/partner"
        workspace_repo="$WORKSPACE_DIR/HomSwagTeam"
    elif [[ "$service" == "mobile" ]]; then
        deploy_repo="$SCRIPT_DIR/repos/mobile"
        workspace_repo="$WORKSPACE_DIR/hom-swag-mobile"
    fi

    if [[ -d "$deploy_repo" ]]; then
        echo "$deploy_repo"
    elif [[ -d "$workspace_repo" ]]; then
        echo "$workspace_repo"
    else
        die "Could not find source for '$service' in deploy/repos/$service or ../$service"
    fi
}

image_tag_for() {
    local service="$1"
    if [[ -n "$TAG_OVERRIDE" ]]; then
        echo "$TAG_OVERRIDE"
        return
    fi

    case "$service" in
        server)    echo "${SERVER_IMAGE_TAG:-latest}" ;;
        reporting) echo "${REPORTING_IMAGE_TAG:-latest}" ;;
        admin)     echo "${ADMIN_IMAGE_TAG:-latest}" ;;
        app)       echo "${APP_IMAGE_TAG:-latest}" ;;
        mobile)    echo "${MOBILE_IMAGE_TAG:-latest}" ;;
        partner)   echo "${PARTNER_IMAGE_TAG:-latest}" ;;
    esac
}

image_name_for() {
    local service="$1"
    echo "$IMAGE_REGISTRY/hom-swag-$service:$(image_tag_for "$service")"
}

push_image_name_for() {
    local service="$1"
    echo "$PUSH_REGISTRY/hom-swag-$service:$(image_tag_for "$service")"
}

sync_source() {
    local source="$1"
    local dest="$2"
    mkdir -p "$dest"

    if command -v rsync &>/dev/null; then
        # Go's module cache is read-only by design. Older build contexts may
        # contain copied cache files, so make the generated destination
        # writable before rsync removes excluded/stale content.
        chmod -R u+w "$dest" 2>/dev/null || true
        rsync -a --delete --delete-excluded \
            --exclude '.git' \
            --exclude '.env' \
            --exclude '.env.*' \
            --exclude 'node_modules' \
            --exclude '.pnpm-store' \
            --exclude '.gocache' \
            --exclude '.gomodcache' \
            --exclude '.nuxt' \
            --exclude '.output' \
            --exclude 'dist' \
            --exclude 'coverage' \
            --exclude 'platforms' \
            --exclude '*.keystore' \
            --exclude '*.jks' \
            --exclude 'tmp' \
            "$source"/ "$dest"/
    else
        warn "rsync not found - using tar fallback without delete cleanup"
        (cd "$source" && tar \
            --exclude='.git' \
            --exclude='.env' \
            --exclude='.env.*' \
            --exclude='node_modules' \
            --exclude='.pnpm-store' \
            --exclude='.gocache' \
            --exclude='.gomodcache' \
            --exclude='.nuxt' \
            --exclude='.output' \
            --exclude='dist' \
            --exclude='coverage' \
            --exclude='platforms' \
            --exclude='*.keystore' \
            --exclude='*.jks' \
            --exclude='tmp' \
            -cf - .) | (cd "$dest" && tar -xf -)
    fi
}

prepare_context() {
    local context_dir="$SCRIPT_DIR/.build-context"
    mkdir -p "$context_dir/repos" "$context_dir/nginx"

    printf '%s\n' \
        '**/.git' \
        '**/.env' \
        '**/.env.*' \
        '**/node_modules' \
        '**/.pnpm-store' \
        '**/.gocache' \
        '**/.gomodcache' \
        '**/.nuxt' \
        '**/.output' \
        '**/dist' \
        '**/coverage' \
        '**/platforms' \
        '**/*.keystore' \
        '**/*.jks' \
        '**/.DS_Store' > "$context_dir/.dockerignore"

    local service source
    for service in "${SERVICES[@]}"; do
        source="$(require_source "$service")"
        log "Preparing $service source from $source"
        sync_source "$source" "$context_dir/repos/$service"
        write_frontend_env_files "$service" "$context_dir/repos/$service"
        if [[ "$service" == "mobile" ]]; then
            local customer_app_source
            customer_app_source="$(require_source app)"
            [[ -f "$customer_app_source/public/HomSwagLogo.png" ]] || die "Mobile web build requires app/public/HomSwagLogo.png"
            sync_source "$customer_app_source/public" "$context_dir/repos/mobile-public"
        fi
    done

    if [[ -d "$SCRIPT_DIR/nginx" ]]; then
        sync_source "$SCRIPT_DIR/nginx" "$context_dir/nginx"
    fi

    echo "$context_dir"
}


build_service() {
    local service="$1"
    local context_dir="$2"
    local image
    local push_image
    image="$(image_name_for "$service")"
    push_image="$(push_image_name_for "$service")"

    local args=(build -f "$SCRIPT_DIR/Containerfile.$service" -t "$image")

    args+=(--platform "$PLATFORM")
    args+=(--provenance=false --sbom=false)

    if [[ "$NO_CACHE" == true ]]; then
        args+=(--no-cache)
    fi

    if [[ "$service" == "admin" || "$service" == "app" || "$service" == "mobile" || "$service" == "partner" ]]; then
        local api_url login_url media_url
        api_url="$(frontend_api_url)"
        login_url="$(frontend_login_url)"
        media_url="$(frontend_media_url)"

        require_prod_url VITE_API_BASE_URL "$api_url"
        require_prod_url VITE_AUTH_API_BASE_URL "$login_url"
        require_prod_url VITE_MEDIA_BASE_URL "$media_url"

        args+=(--build-arg "HS_API_URL=$api_url")
        args+=(--build-arg "HS_LOGIN_URL=$login_url")
        args+=(--build-arg "HS_MEDIA_URL=$media_url")
        args+=(--build-arg "HS_ENABLE_RUM=${VITE_ENABLE_RUM:-false}")
        args+=(--build-arg "HS_RUM_TRACES_ENDPOINT=${VITE_RUM_TRACES_ENDPOINT:-}")
        args+=(--build-arg "HS_DEPLOYMENT_ENVIRONMENT=${VITE_DEPLOYMENT_ENVIRONMENT:-${DEPLOYMENT_ENVIRONMENT:-production}}")
    fi

    if [[ "$service" == "app" ]]; then
        local bff_url server_bff
        bff_url="$(frontend_bff_url)"
        server_bff="$(server_bff_url)"
        require_prod_url VITE_BFF_BASE_URL "$bff_url"
        require_prod_url BFF_BASE_URL "$server_bff"
        args+=(--build-arg "HS_BFF_URL=$bff_url")
        args+=(--build-arg "HS_SERVER_BFF_URL=$server_bff")
        args+=(--build-arg "HS_RUM_SERVICE_NAME=${VITE_APP_RUM_SERVICE_NAME:-customer-app}")
    fi

    if [[ "$service" == "mobile" ]]; then
        local mobile_bff_url mobile_ws_url
        mobile_bff_url="$(frontend_bff_url)"
        mobile_ws_url="${VITE_WS_URL:-}"
        if [[ -z "$mobile_ws_url" ]]; then
            mobile_ws_url="${api_url/https:/wss:}"
            mobile_ws_url="${mobile_ws_url/http:/ws:}"
        fi
        require_prod_url VITE_BFF_BASE_URL "$mobile_bff_url"
        require_prod_url VITE_WS_URL "$mobile_ws_url"
        args+=(--build-arg "HS_BFF_URL=$mobile_bff_url")
        args+=(--build-arg "HS_WS_URL=$mobile_ws_url")
        args+=(--build-arg "HS_MAPS_BROWSER_VALUE=${VITE_GOOGLE_MAPS_API_KEY:-}")
        args+=(--build-arg "HS_FEATURE_MAPS=${VITE_FEATURE_MAPS:-true}")
        args+=(--build-arg "HS_FEATURE_DIRECTIONS=${VITE_FEATURE_DIRECTIONS:-true}")
    fi

    if [[ "$service" == "admin" ]]; then
        local reporting_url customer_app_url partner_app_url signoz_url portainer_url monitor_url
        reporting_url="$(frontend_reporting_url)"
        customer_app_url="${VITE_CUSTOMER_APP_URL:-}"
        partner_app_url="$(admin_utility_url VITE_PARTNER_APP_URL http://localhost:8090 https://partner.homswag.com)"
        signoz_url="$(admin_utility_url VITE_SIGNOZ_URL http://localhost:9080 https://signoz.homswag.com)"
        portainer_url="$(admin_utility_url VITE_PORTAINER_URL https://localhost:9443 https://ports.homswag.com)"
        monitor_url="$(admin_utility_url VITE_MONITOR_URL http://localhost:14318 https://monitor.homswag.com)"
        require_prod_url VITE_REPORTING_BASE_URL "$reporting_url"
        require_prod_url VITE_CUSTOMER_APP_URL "$customer_app_url"
        require_prod_url VITE_PARTNER_APP_URL "$partner_app_url"
        require_prod_url VITE_SIGNOZ_URL "$signoz_url"
        require_prod_url VITE_PORTAINER_URL "$portainer_url"
        require_prod_url VITE_MONITOR_URL "$monitor_url"
        args+=(--build-arg "HS_REPORTING_URL=$reporting_url")
        args+=(--build-arg "HS_REPORTING_SERVICE_URL=$reporting_url")
        args+=(--build-arg "HS_REPORTING_API_TOKEN=${VITE_REPORTING_API_TOKEN:-${REPORTING_API_TOKEN:-}}")
        args+=(--build-arg "HS_CUSTOMER_APP_URL=$customer_app_url")
        args+=(--build-arg "HS_PARTNER_APP_URL=$partner_app_url")
        args+=(--build-arg "HS_SIGNOZ_URL=$signoz_url")
        args+=(--build-arg "HS_PORTAINER_URL=$portainer_url")
        args+=(--build-arg "HS_MONITOR_URL=$monitor_url")
        args+=(--build-arg "HS_RUM_SERVICE_NAME=${VITE_ADMIN_RUM_SERVICE_NAME:-admin-app}")
    fi

    if [[ "$service" == "partner" ]]; then
        local partner_api_url partner_base_url partner_ws_value
        partner_api_url="$(partner_bff_api_url)"
        partner_base_url="$(partner_bff_base_url)"
        partner_ws_value="$(partner_ws_url)"
        require_prod_url VITE_PARTNER_BFF_API_URL "$partner_api_url"
        require_prod_url VITE_PARTNER_BFF_BASE_URL "$partner_base_url"
        require_prod_url VITE_PARTNER_WS_URL "$partner_ws_value"
        args+=(--build-arg "HS_PARTNER_BFF_API_URL=$partner_api_url")
        args+=(--build-arg "HS_PARTNER_BFF_BASE_URL=$partner_base_url")
        args+=(--build-arg "HS_PARTNER_WS_URL=$partner_ws_value")
        args+=(--build-arg "HS_GOOGLE_MAPS_API_KEY=${VITE_GOOGLE_MAPS_API_KEY:-}")
        args+=(--build-arg "HS_FEATURE_MAPS=${VITE_FEATURE_MAPS:-false}")
        args+=(--build-arg "HS_FEATURE_DIRECTIONS=${VITE_FEATURE_DIRECTIONS:-false}")
    fi

    args+=("$context_dir")

    echo ""
    echo -e "${BOLD}━━━  Building $service  ━━━${NC}"
    log "$image"
    "$CONTAINER_BIN" "${args[@]}"
    ok "Built $image"

    if [[ "$PUSH" == true ]]; then
        log "Tagging $image as $push_image"
        "$CONTAINER_BIN" tag "$image" "$push_image"
        log "Pushing $push_image"
        "$CONTAINER_BIN" push "$push_image"
        ok "Pushed $push_image"
    fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      HomSwag - Image Build           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo -e "  Env file : ${BOLD}${ENV_FILE}${NC}"
echo -e "  Image registry : ${BOLD}${IMAGE_REGISTRY}${NC}"
echo -e "  Push registry  : ${BOLD}${PUSH_REGISTRY}${NC}"
echo -e "  Platform       : ${BOLD}${PLATFORM}${NC}"
echo -e "  Services : ${BOLD}${SERVICES[*]}${NC}"
echo -e "  Push     : ${BOLD}${PUSH}${NC}"
echo ""
print_resolved_env

ensure_push_registry_auth

for service in "${SERVICES[@]}"; do
    run_test_gate_for_service "$service"
done

CONTEXT_DIR="$(prepare_context)"

for service in "${SERVICES[@]}"; do
    build_service "$service" "$CONTEXT_DIR"
done

ok "Image build complete."
