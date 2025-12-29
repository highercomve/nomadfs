# Chapter 1.6: NAT Traversal & AutoNAT

Connectivity is the lifeblood of NomadFS. However, most modern devices live behind a **Network Address Translator (NAT)** or Firewall. To ensure nodes can talk to each other, NomadFS employs two key strategies: **UPnP** and **AutoNAT**.

## 1. The Challenge of NAT

If your node is behind a residential router, it can initiate connections to the outside world, but other peers cannot initiate connections to you because your local IP (e.g., `192.168.1.5`) is not reachable from the internet.

## 2. UPnP: Automatic Port Forwarding

NomadFS includes a built-in **UPnP (Universal Plug and Play)** client in `src/network/nat.zig`.

1.  **Discovery (SSDP)**: The node broadcasts a search message to find the router's control URL.
2.  **Negotiation (SOAP)**: The node sends an XML request to the router: "Please forward External Port 9000 to my internal IP on port 9000."
3.  **Outcome**: If successful, your node becomes "Publicly Reachable" even if it's behind a NAT.

## 3. AutoNAT: Reachability Verification

Just because a router says it forwarded a port doesn't mean it actually works (due to ISP firewalls or "Double NAT"). NomadFS uses the **AutoNAT** protocol to verify reachability.

### The Protocol
1.  **Contact Peer**: Your node connects to a known "Public" peer (Bootstrap Node).
2.  **Request `DIAL_BACK`**: Your node sends a `DIAL_BACK` RPC request containing its own listening port.
3.  **Verification**: The remote peer attempts to open a *new* connection to the public IP it observed you coming from.
4.  **Confirmation**:
    *   **Success**: If the peer connects back, you are **Public**.
    *   **Failure**: If the dial-back fails, you are **Private**.

## 4. Node Roles based on Reachability

The result of AutoNAT determines the node's behavior in the DHT layer:

### DHT Server (Public Node)
*   **Role**: Full participant in the DHT.
*   **Behavior**: Joins the routing table of others. Accepts `STORE` and `FIND_NODE` requests. Acts as a "anchor" for the swarm.

### DHT Client (Private/NAT'd Node)
*   **Role**: Passive participant.
*   **Behavior**: Queries the DHT to find data, but does **not** join the routing tables of others. 
*   **Benefit**: This prevents other nodes from trying to connect to an unreachable peer, saving bandwidth and battery.

## 5. Implementation Notes

*   **`DIAL_BACK` RPC**: Defined in `src/dht/rpc.zig`. It is a simple message that triggers a reverse connection attempt.
*   **Dynamic Upgrades**: If a node moves from a 4G network (Private) to a Home WiFi with UPnP (Public), it re-runs AutoNAT and upgrades itself to a DHT Server automatically.

---

**Next Chapters:**
*   [Chapter 2: Discovery Overview](../discovery/overview.md)
