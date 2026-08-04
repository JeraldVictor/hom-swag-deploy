#!/usr/bin/env bash
set -u

usage() {
    cat <<'EOF'
Usage: analyze-memory.sh --container ID [options]

Collect read-only Linux host and container memory evidence. SIGUSR2 is opt-in.

Options:
  --runtime NAME    docker or podman (default: docker)
  --container ID    Container ID/name to inspect
  --samples N       Number of samples (default: 12)
  --interval SEC    Seconds between samples (default: 5)
  --output DIR      Report parent directory (default: ./memory-diagnostics)
  --node-report     Ask Node for a diagnostic report with SIGUSR2
EOF
}

runtime=docker
container=""
samples=12
interval=5
output_parent=./memory-diagnostics
node_report=false

while (($# > 0)); do
    case "$1" in
        --runtime) runtime="${2:-}"; shift 2 ;;
        --container) container="${2:-}"; shift 2 ;;
        --samples) samples="${2:-}"; shift 2 ;;
        --interval) interval="${2:-}"; shift 2 ;;
        --output) output_parent="${2:-}"; shift 2 ;;
        --node-report) node_report=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$runtime" == docker || "$runtime" == podman ]] || { echo "Invalid runtime: $runtime" >&2; exit 2; }
[[ -n "$container" ]] || { echo "--container is required" >&2; exit 2; }
[[ "$samples" =~ ^[1-9][0-9]*$ ]] || { echo "--samples must be a positive integer" >&2; exit 2; }
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || { echo "--interval must be a positive integer" >&2; exit 2; }
[[ -r /proc/meminfo ]] || { echo "This collector must run on the Linux VPS" >&2; exit 2; }
command -v "$runtime" >/dev/null 2>&1 || { echo "$runtime is not installed" >&2; exit 2; }
"$runtime" inspect "$container" >/dev/null 2>&1 || { echo "Container is inaccessible: $container" >&2; exit 2; }

umask 077
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
report_dir="${output_parent%/}/$timestamp"
mkdir -p "$report_dir"

section() {
    local title="$1"
    shift
    {
        echo "## $title"
        "$@" 2>&1 || true
        echo
    } >>"$report_dir/snapshot.txt"
}

shell_section() {
    local title="$1"
    local command="$2"
    {
        echo "## $title"
        bash -c "$command" 2>&1 || true
        echo
    } >>"$report_dir/snapshot.txt"
}

{
    echo "HomSwag VPS memory diagnostic"
    echo "UTC time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname)"
    echo "Runtime/container: $runtime/$container"
    echo "Samples: $samples every ${interval}s"
} >"$report_dir/README.txt"

: >"$report_dir/snapshot.txt"
section "Kernel and architecture" uname -a
section "Uptime and load" uptime
section "Memory summary" free -h
section "Swap" swapon --show --bytes
section "Filesystem usage" df -h
section "Kernel memory details" cat /proc/meminfo
section "Memory pressure" cat /proc/pressure/memory
shell_section "Largest resident processes" "ps -eo pid,ppid,user,rss,vsz,%mem,%cpu,etimes,comm --sort=-rss | head -n 31"
shell_section "OOM evidence" "journalctl -k --since '24 hours ago' --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process|memory cgroup' | tail -n 100"
section "Container memory snapshot" "$runtime" stats --no-stream "$container"
section "Container disk usage" "$runtime" system df

"$runtime" inspect --format $'Name={{.Name}}\nImage={{.Config.Image}}\nStatus={{.State.Status}}\nStartedAt={{.State.StartedAt}}\nOOMKilled={{.State.OOMKilled}}\nRestartCount={{.RestartCount}}\nMemoryLimitBytes={{.HostConfig.Memory}}\nMemoryReservationBytes={{.HostConfig.MemoryReservation}}\nMemorySwapBytes={{.HostConfig.MemorySwap}}' \
    "$container" >"$report_dir/container-inspect.txt" 2>&1 || true
"$runtime" top "$container" -eo pid,ppid,user,rss,vsz,%mem,%cpu,etimes,comm \
    >"$report_dir/container-processes.txt" 2>&1 || true
"$runtime" exec "$container" sh -c '
    cat /proc/1/status
    echo "## smaps_rollup"
    cat /proc/1/smaps_rollup 2>/dev/null || true
    echo "## cgroup"
    for file in memory.current memory.max memory.events memory.stat; do
        test -r "/sys/fs/cgroup/$file" && { echo "### $file"; cat "/sys/fs/cgroup/$file"; }
    done
' >"$report_dir/container-memory.txt" 2>&1 || true

printf 'timestamp,mem_total_bytes,mem_available_bytes,swap_total_bytes,swap_free_bytes\n' >"$report_dir/host-memory.csv"
: >"$report_dir/container-stats.txt"
echo "Collecting $samples samples; approximately $((samples * interval)) seconds..."
for ((sample = 1; sample <= samples; sample += 1)); do
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mem_total=$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)
    mem_available=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo)
    swap_total=$(awk '/^SwapTotal:/ { print $2 * 1024 }' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/ { print $2 * 1024 }' /proc/meminfo)
    printf '%s,%.0f,%.0f,%.0f,%.0f\n' "$now" "$mem_total" "$mem_available" "$swap_total" "$swap_free" >>"$report_dir/host-memory.csv"
    { echo "## $now"; "$runtime" stats --no-stream "$container"; } >>"$report_dir/container-stats.txt" 2>&1 || true
    if ((sample < samples)); then sleep "$interval"; fi
done

if $node_report; then
    echo "Requesting Node diagnostic report..."
    "$runtime" kill --signal=USR2 "$container" >/dev/null
    sleep 2
    mkdir -p "$report_dir/node-reports"
    "$runtime" cp "$container:/app/diagnostics/." "$report_dir/node-reports/" >"$report_dir/node-report-copy.txt" 2>&1 || true
fi

echo "Memory diagnostic saved to: $report_dir"
