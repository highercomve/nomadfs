# Chapter 1.5: Local Discovery with mDNS

In a truly decentralized system, nodes should be able to find each other without relying on a global "phonebook" (the DHT) when they are on the same local network. NomadFS implements **Multicast DNS (mDNS)** style discovery to achieve zero-config connectivity on LANs.

## 1. Why mDNS?

Roaming devices like laptops and phones often move between different WiFi networks. If your phone and your laptop are on the same WiFi, it is much faster and more reliable to sync data directly over the local network than to go through the public internet.

mDNS allows:
*   **Speed**: LAN transfers are usually 10x-100x faster than WAN.
*   **Offline Operation**: You can sync devices even if the building's internet connection is down.
*   **Efficiency**: Reduces bandwidth usage on your internet plan.

## 2. The Implementation

NomadFS uses a simplified mDNS-like protocol over UDP Multicast.

### The Multicast Group
Nodes join the multicast group **`239.255.255.250`** on port **`5353`**. This is a standard reserved address for local discovery.

### The Announcement
Every 30 seconds (and immediately upon startup), each node broadcasts a small UDP packet containing its identity and its local listening port.

**Packet Format (JSON):**
```json
{
  "id": "dacd7680...",
  "port": 9000
}
```

### The Discovery Loop
The `MDNS` struct (`src/network/mdns.zig`) runs a background thread that:
1.  **Listens** for incoming multicast packets.
2.  **Parses** the PeerID and Port.
3.  **Constructs** a full `std.net.Address` using the source IP of the UDP packet.
4.  **Notifies** the `ConnectionManager` via a callback.

## 3. Security Considerations

Even though discovery happens over an unencrypted UDP broadcast, NomadFS remains secure because:
1.  **Noise Handshake**: After discovering a peer via mDNS, the node still performs a full [Noise XXpsk3 Handshake](./noise.md).
2.  **Swarm Key**: If the discovered peer doesn't have the correct Swarm Key, the handshake will fail immediately.
3.  **Untrusted Source**: We only use mDNS to find "potential" peers. We never trust the data they send until the cryptographic handshake is complete.

## 4. Integration

mDNS is integrated directly into the `ConnectionManager`. When a node is configured to listen on a port, it automatically starts the mDNS broadcaster and listener (unless `network.enable_mdns` is set to `false`).

---

**Next Chapters:**
*   [Chapter 1.6: NAT Traversal & AutoNAT](./nat.md)
