import { createClient } from "redis";

const SAFE_CACHE_PATTERNS = ["bff:*", "admin:leaderboard:*", "feature_flags:*"];
const args = process.argv.slice(2);
const action = args[0] ?? "status";

function optionValue(name, fallback) {
	const index = args.indexOf(name);
	return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

function positiveNumber(value, label) {
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		throw new Error(`${label} must be a positive number`);
	}
	return parsed;
}

function parseInfo(raw) {
	const result = {};
	for (const line of raw.split("\n")) {
		if (!line || line.startsWith("#")) continue;
		const separator = line.indexOf(":");
		if (separator > 0) result[line.slice(0, separator)] = line.slice(separator + 1).trim();
	}
	return result;
}

function formatBytes(value) {
	const bytes = Number(value ?? 0);
	if (!Number.isFinite(bytes)) return "unknown";
	const units = ["B", "KiB", "MiB", "GiB", "TiB"];
	let amount = bytes;
	let unit = 0;
	while (amount >= 1024 && unit < units.length - 1) {
		amount /= 1024;
		unit += 1;
	}
	return `${amount.toFixed(unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function namespaceFor(key) {
	const parts = key.split(":");
	if (parts.length < 2) return "<other>";
	return `${parts.slice(0, 2).join(":")}:*`;
}

function printUsage() {
	console.log(`Usage:
  valkey status [--sample-limit 10000] [--threshold 60]
  valkey cleanup [--apply]
  valkey guard [--threshold 60] [--apply]

status  Reports Valkey memory, eviction statistics, TTL sampling, and key namespaces.
cleanup Previews or deletes only: ${SAFE_CACHE_PATTERNS.join(", ")}.
guard   Runs cache cleanup only when Valkey used_memory/maxmemory reaches the threshold.

Deletion is always a dry run unless --apply is present. No values or full key names are printed.`);
}

const host = process.env.VALKEY_HOST || process.env.REDIS_HOST;
const port = process.env.VALKEY_PORT || process.env.REDIS_PORT || "6379";
const username = process.env.VALKEY_USERNAME || process.env.REDIS_USERNAME || "";
const password = process.env.VALKEY_PASSWORD || process.env.REDIS_PASSWORD || "";
const tls = /^(true|1|yes|on)$/i.test(process.env.VALKEY_TLS || process.env.REDIS_TLS || "false");
const database = process.env.VALKEY_DB || process.env.REDIS_DB || "0";

if (["help", "-h", "--help"].includes(action)) {
	printUsage();
	process.exit(0);
}
if (!host) throw new Error("VALKEY_HOST or REDIS_HOST is required");

const credentials = password
	? `${username ? encodeURIComponent(username) : ""}:${encodeURIComponent(password)}@`
	: "";
const client = createClient({
	url: `${tls ? "rediss" : "redis"}://${credentials}${host}:${port}/${database}`,
	socket: { connectTimeout: 10_000, tls, servername: tls ? host : undefined },
});
client.on("error", error => console.error(`Valkey client error: ${error.message}`));

async function scan(pattern, onBatch, limit = Number.POSITIVE_INFINITY) {
	let cursor = "0";
	let scanned = 0;
	do {
		const reply = await client.sendCommand(["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]);
		cursor = String(reply[0]);
		const keys = reply[1].slice(0, Math.max(0, limit - scanned));
		if (keys.length > 0) await onBatch(keys);
		scanned += keys.length;
		if (scanned >= limit) break;
	} while (cursor !== "0");
	return { scanned, complete: cursor === "0" };
}

async function memorySnapshot() {
	const [memoryRaw, statsRaw, keyspaceRaw, dbSizeRaw] = await Promise.all([
		client.sendCommand(["INFO", "MEMORY"]),
		client.sendCommand(["INFO", "STATS"]),
		client.sendCommand(["INFO", "KEYSPACE"]),
		client.sendCommand(["DBSIZE"]),
	]);
	const memory = parseInfo(memoryRaw);
	const stats = parseInfo(statsRaw);
	const keyspace = parseInfo(keyspaceRaw);
	const used = Number(memory.used_memory ?? 0);
	const maximum = Number(memory.maxmemory ?? 0);
	return {
		memory,
		stats,
		keyspace,
		dbSize: Number(dbSizeRaw),
		used,
		maximum,
		percent: maximum > 0 ? (used / maximum) * 100 : null,
	};
}

function printSnapshot(snapshot, threshold) {
	const { memory, stats, keyspace, dbSize, used, maximum, percent } = snapshot;
	const hits = Number(stats.keyspace_hits ?? 0);
	const misses = Number(stats.keyspace_misses ?? 0);
	const hitRatio = hits + misses > 0 ? (hits / (hits + misses)) * 100 : null;

	console.log("Valkey memory status");
	console.log(`  Keys:             ${dbSize.toLocaleString()}`);
	console.log(`  Used memory:      ${formatBytes(used)}`);
	console.log(`  Dataset memory:   ${formatBytes(memory.used_memory_dataset)}`);
	console.log(`  Maxmemory:        ${maximum > 0 ? formatBytes(maximum) : "not reported"}`);
	console.log(`  Internal usage:   ${percent === null ? "unavailable" : `${percent.toFixed(1)}%`}`);
	console.log(`  Warning level:    ${threshold.toFixed(1)}%`);
	console.log(`  Eviction policy:  ${memory.maxmemory_policy ?? "unknown"}`);
	console.log(`  Evicted keys:     ${Number(stats.evicted_keys ?? 0).toLocaleString()}`);
	console.log(`  Expired keys:     ${Number(stats.expired_keys ?? 0).toLocaleString()}`);
	console.log(`  Hit ratio:        ${hitRatio === null ? "unavailable" : `${hitRatio.toFixed(1)}%`}`);
	console.log(`  Fragmentation:    ${memory.mem_fragmentation_ratio ?? "unknown"}`);
	for (const [db, value] of Object.entries(keyspace)) console.log(`  ${db}:              ${value}`);

	if (percent !== null && percent >= threshold) {
		console.log(`\nWARNING: internal Valkey usage is at or above ${threshold.toFixed(1)}%.`);
	}
	console.log("Note: DigitalOcean dashboard memory is an OS-level metric and can differ from this ratio.");
}

async function reportNamespaces(sampleLimit) {
	const namespaces = new Map();
	let expiring = 0;
	let persistent = 0;
	let sampledBytes = 0;

	const result = await scan("*", async keys => {
		for (let offset = 0; offset < keys.length; offset += 50) {
			const chunk = keys.slice(offset, offset + 50);
			const details = await Promise.all(
				chunk.map(async key => {
					const [ttl, bytes] = await Promise.all([
						client.sendCommand(["PTTL", key]),
						client.sendCommand(["MEMORY", "USAGE", key]),
					]);
					return { key, ttl: Number(ttl), bytes: Number(bytes ?? 0) };
				})
			);
			for (const detail of details) {
				if (detail.ttl >= 0) expiring += 1;
				else if (detail.ttl === -1) persistent += 1;
				sampledBytes += detail.bytes;
				const namespace = namespaceFor(detail.key);
				const current = namespaces.get(namespace) ?? { keys: 0, bytes: 0 };
				current.keys += 1;
				current.bytes += detail.bytes;
				namespaces.set(namespace, current);
			}
		}
	}, sampleLimit);

	console.log(`\nKey sample (${result.scanned.toLocaleString()}${result.complete ? "" : "+"} keys)`);
	console.log(`  Expiring:          ${expiring.toLocaleString()}`);
	console.log(`  No expiry:         ${persistent.toLocaleString()}`);
	console.log(`  Sampled memory:    ${formatBytes(sampledBytes)}`);
	console.log("  Largest sampled namespaces:");
	for (const [namespace, data] of [...namespaces.entries()].sort((a, b) => b[1].bytes - a[1].bytes).slice(0, 15)) {
		console.log(`    ${namespace.padEnd(28)} ${String(data.keys).padStart(8)} keys  ${formatBytes(data.bytes).padStart(10)}`);
	}
	if (!result.complete) console.log(`  Sample capped at ${sampleLimit.toLocaleString()} keys; increase --sample-limit for broader coverage.`);
}

async function cleanupSafeCaches(apply) {
	let total = 0;
	for (const pattern of SAFE_CACHE_PATTERNS) {
		let count = 0;
		await scan(pattern, async keys => {
			count += keys.length;
			if (apply) await client.sendCommand(["UNLINK", ...keys]);
		});
		total += count;
		console.log(`  ${pattern.padEnd(28)} ${count.toLocaleString()} key(s)${apply ? " removed" : ""}`);
	}
	console.log(`${apply ? "Removed" : "Would remove"} ${total.toLocaleString()} cache key(s).`);
	if (!apply) console.log("Dry run only. Repeat with --apply to unlink these cache keys.");
	return total;
}

try {
	await client.connect();
	const threshold = positiveNumber(
		optionValue("--threshold", process.env.VALKEY_MEMORY_WARN_PERCENT || "60"),
		"--threshold"
	);

	if (action === "status") {
		const limit = positiveNumber(optionValue("--sample-limit", "10000"), "--sample-limit");
		const snapshot = await memorySnapshot();
		printSnapshot(snapshot, threshold);
		await reportNamespaces(limit);
	} else if (action === "cleanup") {
		console.log("Safe cache cleanup");
		await cleanupSafeCaches(args.includes("--apply"));
	} else if (action === "guard") {
		const snapshot = await memorySnapshot();
		printSnapshot(snapshot, threshold);
		if (snapshot.percent === null) {
			throw new Error("Valkey did not report maxmemory; the guard cannot calculate a threshold");
		}
		if (snapshot.percent < threshold) {
			console.log("Memory is below the guard threshold; no cleanup needed.");
		} else {
			console.log("\nThreshold reached; checking approved cache namespaces only.");
			await cleanupSafeCaches(args.includes("--apply"));
		}
	} else {
		printUsage();
		process.exitCode = 1;
	}
} finally {
	if (client.isOpen) await client.quit();
}
