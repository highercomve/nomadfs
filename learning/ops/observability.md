# Metrics & Observability

NomadFS exposes internal metrics to help operators monitor the health and performance of their nodes.

## 1. Metrics Endpoint

By default, metrics are exposed via a simple HTTP endpoint on `127.0.0.1:9090/metrics` (if enabled in build).

**Note**: In the current MVP, metrics are primarily dumped to logs or inspected via the CLI `nomadfs stats`.

## 2. Key Metrics to Watch

| Metric Name | Type | Description |
| :--- | :--- | :--- |
| `transport.bytes_sent` | Counter | Total bytes sent over the network. |
| `transport.bytes_received` | Counter | Total bytes received. |
| `dht.peers_count` | Gauge | Number of active peers in the routing table. |
| `dht.lookup_latency` | Histogram | Time taken to complete a DHT lookup. |
| `storage.blocks_stored` | Gauge | Number of unique blocks in local storage. |
| `storage.bytes_used` | Gauge | Disk space used by blocks (in bytes). |
| `yamux.streams_active` | Gauge | Current number of open substreams. |

## 3. Logs

NomadFS uses structured logging.

- **INFO**: startup, shutdown, significant state changes.
- **WARN**: transient errors (connection drops, timeout), resource limits.
- **ERROR**: fatal errors, data corruption, panic conditions.
- **DEBUG**: detailed protocol tracing (verbose).

### Log Rotation
NomadFS does not handle log rotation internally. Use standard tools like `logrotate` if redirecting output to a file.
