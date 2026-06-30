#!/bin/sh
set -eu

CLICKHOUSE_HOST="${SIGNOZ_CLICKHOUSE_HOST:-signoz}"
CLICKHOUSE_PORT="${SIGNOZ_CLICKHOUSE_PORT:-9000}"
RETENTION_DAYS="${SIGNOZ_RETENTION_DAYS:-7}"
MAX_BYTES="${SIGNOZ_MAX_BYTES:-5368709120}"
INTERVAL_SECONDS="${SIGNOZ_RETENTION_INTERVAL_SECONDS:-3600}"
TRIM_STEP_SECONDS="${SIGNOZ_RETENTION_TRIM_STEP_SECONDS:-21600}"
MUTATIONS_SYNC="${SIGNOZ_RETENTION_MUTATIONS_SYNC:-1}"

log() {
	printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

query() {
	clickhouse-client \
		--host "$CLICKHOUSE_HOST" \
		--port "$CLICKHOUSE_PORT" \
		--multiquery \
		--query "$1"
}

query_scalar() {
	clickhouse-client \
		--host "$CLICKHOUSE_HOST" \
		--port "$CLICKHOUSE_PORT" \
		--query "$1"
}

wait_for_clickhouse() {
	while ! query_scalar "SELECT 1" >/dev/null 2>&1; do
		log "Waiting for ClickHouse at ${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT} ..."
		sleep 5
	done
}

clickhouse_bytes() {
	query_scalar "
		SELECT toUInt64(coalesce(sum(bytes_on_disk), 0))
		FROM system.parts
		WHERE active
		  AND database LIKE 'signoz_%'
	"
}

apply_window() {
	window_seconds="$1"
	now_seconds="$(date +%s)"
	cutoff_seconds=$((now_seconds - window_seconds))
	cutoff_millis=$((cutoff_seconds * 1000))
	cutoff_nanos=$((cutoff_seconds * 1000000000))
	cutoff_datetime="$(date -u -d "@${cutoff_seconds}" "+%Y-%m-%d %H:%M:%S")"

	log "Applying SigNoz retention window: ${window_seconds}s"

	query "
		SET mutations_sync = ${MUTATIONS_SYNC};

		ALTER TABLE signoz_analytics.rule_state_history_v0
			DELETE WHERE unix_milli < ${cutoff_millis};

		ALTER TABLE signoz_logs.logs_v2
			DELETE WHERE timestamp < ${cutoff_nanos};
		ALTER TABLE signoz_logs.logs_v2_resource
			DELETE WHERE seen_at_ts_bucket_start < ${cutoff_seconds};
		ALTER TABLE signoz_logs.logs_attribute_keys
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_logs.logs_resource_keys
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_logs.tag_attributes_v2
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_logs.usage
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');

		ALTER TABLE signoz_meter.samples
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_meter.samples_agg_1d
			DELETE WHERE unix_milli < ${cutoff_millis};

		ALTER TABLE signoz_metrics.exp_hist
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.samples_v2
			DELETE WHERE timestamp_ms < ${cutoff_millis};
		ALTER TABLE signoz_metrics.samples_v4
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.samples_v4_agg_5m
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.samples_v4_agg_30m
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.time_series_v2
			DELETE WHERE timestamp_ms < ${cutoff_millis};
		ALTER TABLE signoz_metrics.time_series_v4
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.time_series_v4_6hrs
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.time_series_v4_1day
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.time_series_v4_1week
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_metrics.usage
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');

		ALTER TABLE signoz_traces.signoz_index_v2
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.signoz_index_v3
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.signoz_spans
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.signoz_error_index_v2
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.durationSort
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.dependency_graph_minutes_v2
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_traces.span_attributes
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_traces.span_attributes_keys
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_traces.tag_attributes_v2
			DELETE WHERE unix_milli < ${cutoff_millis};
		ALTER TABLE signoz_traces.top_level_operations
			DELETE WHERE time < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_traces.trace_summary
			DELETE WHERE end < toDateTime64('${cutoff_datetime}', 9, 'UTC');
		ALTER TABLE signoz_traces.traces_v3_resource
			DELETE WHERE seen_at_ts_bucket_start < ${cutoff_seconds};
		ALTER TABLE signoz_traces.usage
			DELETE WHERE timestamp < toDateTime('${cutoff_datetime}', 'UTC');
		ALTER TABLE signoz_traces.usage_explorer
			DELETE WHERE timestamp < toDateTime64('${cutoff_datetime}', 9, 'UTC');
	"
}

cleanup_once() {
	retention_seconds=$((RETENTION_DAYS * 86400))
	if ! apply_window "$retention_seconds"; then
		return 1
	fi

	bytes="$(clickhouse_bytes)"
	log "SigNoz ClickHouse active telemetry size: ${bytes} bytes (limit ${MAX_BYTES})"

	window_seconds="$retention_seconds"
	while [ "$bytes" -gt "$MAX_BYTES" ] && [ "$window_seconds" -gt 0 ]; do
		window_seconds=$((window_seconds - TRIM_STEP_SECONDS))
		if [ "$window_seconds" -lt 0 ]; then
			window_seconds=0
		fi
		log "SigNoz data exceeds limit; trimming retention window to ${window_seconds}s"
		apply_window "$window_seconds"
		bytes="$(clickhouse_bytes)"
		log "SigNoz ClickHouse active telemetry size after trim: ${bytes} bytes"
	done

	if [ "$bytes" -gt "$MAX_BYTES" ]; then
		log "WARNING: SigNoz data is still above ${MAX_BYTES} bytes after strict trimming."
	fi
}

wait_for_clickhouse
log "Starting SigNoz retention loop: max ${RETENTION_DAYS} day(s), max ${MAX_BYTES} bytes, interval ${INTERVAL_SECONDS}s"

while true; do
	cleanup_once || log "WARNING: SigNoz retention pass failed"
	sleep "$INTERVAL_SECONDS"
done
