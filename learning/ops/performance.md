# Performance Targets & Limits

## 1. Design Targets

NomadFS is optimized for:
1.  **High Throughput**: Maximizing sequential I/O for large file transfers.
2.  **Low Latency Discovery**: Finding peers and content within < 500ms on WAN.
3.  **Low Resource Footprint**: Running comfortably on constrained devices (512MB RAM).

## 2. Theoretical Limits (v0.1)

| Resource | Limit | Constraint |
| :--- | :--- | :--- |
| **Max File Size** | ~4 PB | Merkle DAG depth limit (effectively infinite for practical use). |
| **Max Block Size** | 256 KB | Fixed chunk size for deduplication efficiency. |
| **Max Peers** | ~1000 | Current limitation of linear vector clock scans (to be optimized). |
| **Max DHT Depth** | 160 bits | SHA-1 / XOR metric space. |

## 3. Practical Limitations

### Scalability
- **Vector Clocks**: The current O(N) implementation for vector clocks limits the efficient swarm size to a few hundred nodes. Beyond this, sync operations may become CPU-bound.
- **Memory Usage**: RAM usage scales primarily with the number of open connections and the size of the routing table.

### Network
- **Throughput**: Limited by the encryption overhead of ChaCha20-Poly1305 (approx. 1-2 GB/s on modern CPUs) and TCP window scaling. Yamux helps avoid head-of-line blocking but introduces slight framing overhead.

## 4. Optimization Tips

- **Increase `ulimit -n`**: Ensure the OS allows enough open file descriptors for peer connections.
- **Use SSDs**: Random seek times significantly impact block storage performance.
- **Enable AES-NI**: Ensure your CPU supports hardware crypto instructions (automatically used by Zig if available).
