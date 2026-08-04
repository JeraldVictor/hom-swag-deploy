#!/usr/bin/env bash
set -u

usage() {
    cat <<'EOF'
Usage: cleanup-vps.sh [options]

Preview aged deployment artifacts by default; pass --apply to delete them.
This script never cleans Docker volumes or deploy/volume-data.
EOF
}

mode=dry-run
root=$PWD
runtime=docker
logs_dir=./logs
uploads_dir=./uploads/temp
diagnostics_dir=./diagnostics
memory_reports_dir=./memory-diagnostics
logs_days=7
temp_hours=24
diagnostics_days=7
docker_prune=false
reporting_containers=()
reporting_count=0

while (($# > 0)); do
    case "$1" in
        --apply) mode=apply; shift ;;
        --root) root="${2:-}"; shift 2 ;;
        --runtime) runtime="${2:-}"; shift 2 ;;
        --logs-dir) logs_dir="${2:-}"; shift 2 ;;
        --uploads-dir) uploads_dir="${2:-}"; shift 2 ;;
        --diagnostics-dir) diagnostics_dir="${2:-}"; shift 2 ;;
        --memory-reports-dir) memory_reports_dir="${2:-}"; shift 2 ;;
        --logs-days) logs_days="${2:-}"; shift 2 ;;
        --temp-hours) temp_hours="${2:-}"; shift 2 ;;
        --diagnostics-days) diagnostics_days="${2:-}"; shift 2 ;;
        --reporting-container) reporting_containers[$reporting_count]="${2:-}"; reporting_count=$((reporting_count + 1)); shift 2 ;;
        --docker-prune) docker_prune=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

for value in "$logs_days" "$temp_hours" "$diagnostics_days"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Retention values must be positive integers" >&2; exit 2; }
done
[[ "$runtime" == docker || "$runtime" == podman ]] || { echo "Invalid runtime: $runtime" >&2; exit 2; }
root=$(cd "$root" 2>/dev/null && pwd -P) || { echo "Invalid deploy root" >&2; exit 2; }
[[ -f "$root/compose.yaml" && -f "$root/deploy.sh" && "$root" != / ]] || { echo "Refusing non-deploy root" >&2; exit 2; }

resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then printf '%s\n' "${path%/}"; else printf '%s\n' "$root/${path#./}"; fi
}

logs_dir=$(resolve_path "$logs_dir")
uploads_dir=$(resolve_path "$uploads_dir")
diagnostics_dir=$(resolve_path "$diagnostics_dir")
memory_reports_dir=$(resolve_path "$memory_reports_dir")

validate_target() {
    local path="$1"
    case "$path" in
        /|"$root"|"$(dirname "$root")"|"${HOME:-/nonexistent}") echo "Refusing unsafe cleanup target: $path" >&2; exit 2 ;;
    esac
}
for target in "$logs_dir" "$uploads_dir" "$diagnostics_dir" "$memory_reports_dir"; do validate_target "$target"; done

file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0; }
deleted=0
bytes=0

open_file_state() {
    local file="$1"
    if command -v lsof >/dev/null 2>&1; then
        if lsof -t -- "$file" >/dev/null 2>&1; then echo open; else echo closed; fi
    elif command -v fuser >/dev/null 2>&1; then
        if fuser "$file" >/dev/null 2>&1; then echo open; else echo closed; fi
    else
        echo unknown
    fi
}

clean_path() {
    local path="$1" age_type="$2" age="$3"
    [[ -d "$path" ]] || return
    while IFS= read -r -d '' file; do
        local open_state
        open_state=$(open_file_state "$file")
        if [[ "$open_state" == open ]]; then echo "SKIP open file: $file"; continue; fi
        if [[ "$file" == "$logs_dir/app.log" && "$open_state" == unknown ]]; then
            echo "SKIP app.log because neither lsof nor fuser can verify that it is closed: $file"
            continue
        fi
        local size
        local action=DRY-RUN
        [[ "$mode" == apply ]] && action=DELETE
        size=$(file_size "$file")
        printf '%s %s bytes %s\n' "$action" "$size" "$file"
        if [[ "$mode" == apply ]]; then rm -f -- "$file"; deleted=$((deleted + 1)); bytes=$((bytes + size)); fi
    done < <(
        if [[ "$age_type" == minutes ]]; then find "$path" -xdev -type f -mmin "+$age" -print0
        else find "$path" -xdev -type f -mtime "+$age" -print0
        fi
    )
    if [[ "$mode" == apply ]]; then find "$path" -xdev -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true; fi
}

echo "HomSwag deploy cleanup: $mode"
echo "Protected: $root/volume-data and all Docker volumes"
df -h "$root" 2>/dev/null || true
clean_path "$logs_dir" days "$logs_days"
clean_path "$uploads_dir" minutes "$((temp_hours * 60))"
clean_path "$diagnostics_dir" days "$diagnostics_days"
clean_path "$memory_reports_dir" days "$diagnostics_days"

for ((index = 0; index < reporting_count; index += 1)); do
    container=${reporting_containers[$index]}
    echo "Reporting temp cleanup ($mode): $container"
    "$runtime" exec "$container" sh -c '
        mode=$1; age=$2; path=/tmp/reports
        test -d "$path" || exit 0
        find "$path" -xdev -type f -mmin "+$age" -print
        if test "$mode" = apply; then find "$path" -xdev -type f -mmin "+$age" -exec rm -f -- {} +; fi
    ' cleanup "$mode" "$((temp_hours * 60))" || true
done

if $docker_prune; then
    command -v "$runtime" >/dev/null 2>&1 || { echo "$runtime is unavailable" >&2; exit 2; }
    until_filter="$((logs_days * 24))h"
    if [[ "$mode" == apply ]]; then
        "$runtime" container prune -f --filter "until=$until_filter"
        "$runtime" image prune -f --filter "until=$until_filter"
        "$runtime" builder prune -f --filter "until=$until_filter"
    else
        echo "DRY-RUN would prune stopped containers, dangling images, and build cache older than $until_filter"
    fi
fi

df -h "$root" 2>/dev/null || true
if [[ "$mode" == apply ]]; then echo "Deleted host files: $deleted; reclaimed host bytes: $bytes"; else echo "Dry run only; review and repeat with --apply."; fi
