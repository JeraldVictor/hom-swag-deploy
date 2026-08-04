# VPS operations

Run these commands from the deployment checkout. They automatically use the selected Compose
profile and its `.env.local` or `.env.prod` file.

## Memory analysis

Collect ten minutes of host and server-container evidence:

```bash
./deploy.sh --env prod memory server --samples 60 --interval 10
```

Reports are written beneath `MEMORY_REPORTS_PATH` (default `./memory-diagnostics`). They include
host availability and swap, Linux pressure/OOM evidence, largest processes, container RSS/cgroup
state, and samples over time. Environment variables are not collected.

Request a lower-overhead Node diagnostic JSON as part of the capture:

```bash
./deploy.sh --env prod memory server --samples 1 --interval 1 --node-report
```

The server Compose service enables SIGUSR2 diagnostic reports and writes them through the
`DIAGNOSTICS_SOURCE` host mount. Environment variables and network interfaces are excluded. Avoid
heap snapshots on a memory-starved production process.

## Logs and temporary data

Preview aged files:

```bash
./deploy.sh --env prod cleanup
```

Apply after reviewing the preview:

```bash
./deploy.sh --env prod cleanup --apply
```

This covers the configured server log directory, temporary uploads, Node/memory diagnostics, and
the reporting service's `/tmp/reports`. It never touches `volume-data` or Docker volumes.

Optional Docker garbage collection removes stopped containers, dangling images, and build cache,
but not volumes:

```bash
./deploy.sh --env prod cleanup --apply --docker-prune
```

Retention defaults are configured in the environment file:

```dotenv
CLEANUP_LOG_DAYS=7
CLEANUP_TEMP_HOURS=24
CLEANUP_DIAGNOSTICS_DAYS=7
```

After validating one manual dry run and apply, schedule it from the deployment checkout. For
example, this daily cron entry sends its output to journald instead of another file:

```cron
15 3 * * * cd /opt/homswag/deploy && ./deploy.sh --env prod cleanup --apply 2>&1 | /usr/bin/logger -t homswag-cleanup
```

Production application logs go to stdout with `LOG_FILE_ENABLED=false`. Compose rotates Docker
JSON logs according to `DOCKER_LOG_MAX_SIZE` and `DOCKER_LOG_MAX_FILE`. Recreate existing services
after changing those limits; never truncate files under `/var/lib/docker/containers` manually.

## Managed Valkey memory

Inspect Valkey without printing credentials, values, or full key names:

```bash
./deploy.sh --env prod valkey status
```

The report shows Valkey's internal `used_memory/maxmemory` ratio, eviction policy, evictions,
expiry behavior, and sampled key namespaces. DigitalOcean's dashboard percentage is an OS-level
cluster metric, so it will not exactly match Valkey's internal ratio.

Preview deletion of application cache keys only:

```bash
./deploy.sh --env prod valkey cleanup
```

Apply that cache cleanup explicitly:

```bash
./deploy.sh --env prod valkey cleanup --apply
```

The approved patterns are `bff:*`, `admin:leaderboard:*`, and `feature_flags:*`. OTP, rate-limit,
tracking session, and cart keys are deliberately excluded.

To guard the internal Valkey ratio at 60%, first run a dry run:

```bash
./deploy.sh --env prod valkey guard --threshold 60
```

If the status report confirms these cache namespaces account for meaningful memory, the applying
form can be scheduled every five minutes:

```cron
*/5 * * * * cd /opt/homswag/deploy && ./deploy.sh --env prod valkey guard --threshold 60 --apply 2>&1 | /usr/bin/logger -t homswag-valkey-guard
```

This is a cache-pressure guard, not a guaranteed DigitalOcean dashboard ceiling. If non-cache
namespaces dominate memory, use the status report to shorten their retention or move cache and
operational state to separate Valkey databases/clusters. Because the current database is mixed,
do not use `allkeys-lru` without accepting that OTP, rate-limit, session, and cart keys may be
evicted. Configure a DigitalOcean memory alert at 60% independently, and stop the scheduled guard
if it repeatedly clears caches without lowering memory to avoid cache churn.
