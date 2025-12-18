# The Big Picture: 4 Layers of NomadFS

NomadFS is built like a stack where higher layers depend on lower ones.

## Layer 1: Networking (The Roads)
*   **Problem**: How do I talk securely to a peer over the internet?
*   **Solution**: TCP + Noise Protocol (XXpsk3) + Yamux.
*   **Outcome**: A secure, multiplexed bidirectional pipe. It knows nothing about files, just encrypted bytes.

## Layer 2: Discovery & Storage (The Components)
*   **Discovery (DHT)**: The "Phonebook." Uses the network to find which PeerIDs host specific Content IDs (CIDs).
*   **Storage**: The "Warehouse." Local Merkle DAG engine. It's nullable for mobile devices.

## Layer 3: Block Exchange (The Brain)
*   **Problem**: How do I orchestrate DHT, Network, and Storage to move data?
*   **Solution**: **Block Manager** (Coordinator).
*   **Outcome**: The coordinator checks local storage, asks the DHT for missing blocks, connects via the Network, and transfers data.

## Layer 4: Application / API
*   **Problem**: How does the user interact with the system?
*   **Solution**: High-level CLI or Shared Library (for Mobile).
*   **Outcome**: Simple `put` and `get` operations that hide the complexity of the layers below.
