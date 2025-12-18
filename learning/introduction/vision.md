# Vision and Philosophy

NomadFS is not just another file system; it is a solution for a world where our devices are constantly on the move.

## 1. The Problem: Roaming Devices

Most distributed systems (like HDFS or traditional RAID) assume that nodes are stationary, have fixed IP addresses, and are always online. In the real world:
*   **Laptops** close and open in different cities.
*   **Phones** switch between LTE and Wi-Fi.
*   **Home Servers** might have flaky residential connections.

When these devices change IPs or go offline, traditional systems often "panic," trying to re-replicate data they think is lost, or they simply stop working.

## 2. The NomadFS Goal

Create a private, decentralized distributed file system optimized for these **Roaming Devices**.

### Core Philosophy: AP over CP
In terms of the **CAP Theorem** (Consistency, Availability, Partition Tolerance), NomadFS prioritizes **Availability** and **Partition Tolerance** (AP).

*   **Offline Writes ($W=1$)**: You must be able to save a file to your local device even if you are in the middle of the woods with no internet.
*   **Eventual Consistency**: When you reconnect to the swarm, the system automatically synchronizes your changes and resolves conflicts using mathematical models (Vector Clocks).

## 3. Privacy by Default

NomadFS assumes the underlying network is hostile. 
*   **Private Swarms**: Only nodes with the Pre-Shared Key (PSK) can join.
*   **End-to-End Encryption**: Data is encrypted before it ever leaves your device. Storage nodes (peers) can store your data without being able to read its contents.
