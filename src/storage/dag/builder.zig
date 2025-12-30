const std = @import("std");
const node_mod = @import("node.zig");
const MerkleNode = node_mod.MerkleNode;
const DagLink = node_mod.DagLink;
const StorageEngine = @import("../engine.zig").StorageEngine;
const block_mod = @import("../block.zig");
const Block = block_mod.Block;

// IPFS default chunk size is 256KB
const CHUNK_SIZE = 256 * 1024;
const MAX_LINKS = 174;

pub const Layout = enum {
    Balanced, // B-Tree
    Linear,   // Linked List
};

pub const DagBuilder = struct {
    allocator: std.mem.Allocator,
    store: *StorageEngine,
    layout: Layout,

    /// Main entry point: Turns a file reader into a Root CID
    pub fn build(self: *DagBuilder, reader: anytype) ![]const u8 {
        // We accumulate the leaf nodes' metadata (CIDs and sizes), not their data.
        // This keeps memory usage low even for large files.
        var leaf_metadata = std.ArrayList(DagLink).init(self.allocator);
        defer {
            for (leaf_metadata.items) |link| {
                self.allocator.free(link.name);
                self.allocator.free(link.cid);
            }
            leaf_metadata.deinit();
        }

        // Buffer for reading chunks (Zero-Copy Strategy: Reuse this buffer)
        const buffer = try self.allocator.alloc(u8, CHUNK_SIZE);
        defer self.allocator.free(buffer);

        while (true) {
            const bytes_read = try reader.read(buffer);
            if (bytes_read == 0) break;

            const slice = buffer[0..bytes_read];

            // 1. Create a transient Leaf Node (Blob)
            // We pass the slice directly. Note: We must persist this BEFORE reusing 'buffer'.
            // Level 0 = Leaf
            var leaf = MerkleNode.init(self.allocator, slice, 0);
            defer leaf.deinit();

            // 2. Persist to Disk (Write-Ahead)
            // This copies the data from RAM to Disk.
            const cid = try self.persist(leaf);
            
            // 3. Keep Metadata only
            const link_name = try std.fmt.allocPrint(self.allocator, "", .{}); // Empty name for leaves in list
            const cid_copy = try self.allocator.dupe(u8, cid);
            
            try leaf_metadata.append(DagLink{
                .name = link_name,
                .cid = cid_copy,
                .size = leaf.totalSize(),
            });

            // Loop continues, 'buffer' is overwritten in next read.
        }

        // Step B & C: Linking
        return switch (self.layout) {
            .Balanced => try self.buildBalanced(leaf_metadata.items),
            .Linear => try self.buildLinear(leaf_metadata.items),
        };
    }
    
    // Helpers

    /// Implements a Balanced Tree (wide, shallow)
    fn buildBalanced(self: *DagBuilder, links: []const DagLink) ![]const u8 {
        if (links.len == 0) {
            // Edge case: Empty file. Create an empty node.
            var empty = MerkleNode.init(self.allocator, "", 0);
            defer empty.deinit();
            return self.persist(empty);
        }

        if (links.len == 1) {
            // Optimization: If we have only 1 chunk, the Root IS that chunk.
            // But wait, usually the Root is a "Parent" that points to the chunk.
            // IPFS convention: A small file *can* be just a Blob.
            // However, to be consistent with our DAG structure where Root is usually a List:
            // Let's wrap it in a Parent if it was a list logic, but if it's the result of recursion...
            // Actually, if we are here, 'links' are the children.
            // If we have 1 child, should we wrap it? Yes, if we want a metadata wrapper.
            // But standard Merkle trees often collapse the root if it fits.
            // For simplicity/consistency: We will wrap even single chunks into a root node 
            // if they came from the "leaf metadata" list. 
            // BUT, strictly speaking, buildBalanced is recursive. 
            // If we are at the top level and have 1 link, that link IS the root.
            return self.allocator.dupe(u8, links[0].cid);
        }

        // We need to create a new layer of parents
        var parent_links = std.ArrayList(DagLink).init(self.allocator);
        defer {
            // We don't own the 'links' passed in (they belong to caller), 
            // but we own the NEW links we create here.
            // The caller handles freeing the passed 'links'.
            // We must handle the cleanup of 'parent_links' if we fail, 
            // but success returns a CID, so we shouldn't destroy the return value.
            // Actually, we are building intermediate nodes. We persist them, get CIDs.
            // We only need to return the Root CID.
            for (parent_links.items) |link| {
                self.allocator.free(link.name);
                self.allocator.free(link.cid);
            }
            parent_links.deinit();
        }

        var i: usize = 0;
        while (i < links.len) {
            const end = @min(i + MAX_LINKS, links.len);
            const batch = links[i..end];

            // Create Parent (Level > 0)
            // Note: We don't know the level easily here without tracking it, 
            // but typically we just say 1 (Parent). Level is mostly debug/metadata.
            var parent = MerkleNode.init(self.allocator, "", 1);
            defer parent.deinit();

            for (batch, 0..) |child_link, idx| {
                // We must duplicate the data because MerkleNode.links owns its data
                const name = try std.fmt.allocPrint(self.allocator, "link-{d}", .{idx});
                const cid_copy = try self.allocator.dupe(u8, child_link.cid);
                
                try parent.links.append(self.allocator, DagLink{
                    .name = name,
                    .cid = cid_copy,
                    .size = child_link.size,
                });
            }

            const parent_cid = try self.persist(parent);
            
            // Add to next layer
            const pl_name = try std.fmt.allocPrint(self.allocator, "link-{d}", .{parent_links.items.len});
            const pl_cid = try self.allocator.dupe(u8, parent_cid);
            
            // Calculate parent size (sum of children)
            // Note: parent.totalSize() includes its own data (0) + sum of links
            const p_size = parent.totalSize();

            try parent_links.append(DagLink{
                .name = pl_name,
                .cid = pl_cid,
                .size = p_size,
            });

            i = end;
        }

        // Recursion
        if (parent_links.items.len == 1) {
            // We have converged to a single root
            return self.allocator.dupe(u8, parent_links.items[0].cid);
        } else {
            return self.buildBalanced(parent_links.items);
        }
    }

    /// Implements a Linear Layout (Linked List)
    fn buildLinear(self: *DagBuilder, leaf_links: []const DagLink) ![]const u8 {
        if (leaf_links.len == 0) {
             var empty = MerkleNode.init(self.allocator, "", 0);
             defer empty.deinit();
             return self.persist(empty);
        }
        
        // We iterate backwards.
        // Last node points to nothing.
        // Second to last points to Last.
        // ...
        // First points to Second.
        
        var next_cid: ?[]const u8 = null;
        var next_size: u64 = 0;

        // We need to manage memory for the CIDs we generate
        var generated_cids = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (generated_cids.items) |c| self.allocator.free(c);
            generated_cids.deinit();
        }

        var i: usize = leaf_links.len;
        while (i > 0) {
            i -= 1;
            const current_leaf = leaf_links[i];

            // Create a wrapper node that holds the Leaf + Link to Next
            // In IPFS trickledags, it's more complex, but for "Linear", 
            // a node essentially wraps the data block and points to the next.
            // BUT: We already persisted the LEAF nodes (data blobs).
            // So we are creating a "Spine" of internal nodes.
            // SpineNode[i] -> [Leaf[i], SpineNode[i+1]]
            
            var spine = MerkleNode.init(self.allocator, "", 1); // Internal
            defer spine.deinit();

            // Link 1: The Data Chunk (Leaf)
            {
                const name = try std.allocator.dupe(self.allocator, u8, "data");
                const cid = try self.allocator.dupe(u8, current_leaf.cid);
                try spine.links.append(self.allocator, DagLink{
                    .name = name,
                    .cid = cid,
                    .size = current_leaf.size,
                });
            }

            // Link 2: The Next Node (if exists)
            if (next_cid) |ncid| {
                const name = try std.allocator.dupe(self.allocator, u8, "next");
                const cid = try self.allocator.dupe(u8, ncid);
                try spine.links.append(self.allocator, DagLink{
                    .name = name,
                    .cid = cid,
                    .size = next_size,
                });
            }

            const spine_cid = try self.persist(spine);
            try generated_cids.append(spine_cid); // Track for cleanup, though persist dupe returns caller-owned

            // Prepare for next iteration (going backwards)
            next_cid = spine_cid; // persist returns a new allocated slice
            next_size = spine.totalSize();
        }
        
        // We want to return the last generated CID (which corresponds to index 0),
        // but pass ownership to caller.
        // generated_cids stores them, we need to extract the last one.
        // Actually, 'next_cid' holds the root. But 'next_cid' is owned by the loop's alloc logic?
        // persist() returns an allocated slice.
        // We put it in generated_cids.
        // We want to return 'next_cid' and NOT free it in defer.
        
        // Let's refine the cleanup logic.
        // persist returns owned slice.
        // We assign it to next_cid.
        // In the next loop, we add it to spine.
        // spine copies it.
        // So the old next_cid is no longer needed after being added to spine?
        // Wait, 'spine.links.append' dupes the CID (based on my code above).
        // So 'next_cid' must be freed after loop, EXCEPT the final one (Root).
        
        // Simplified cleanup:
        // We will manually free the intermediate CIDs.
        
        return self.allocator.dupe(u8, next_cid.?);
    }

    fn persist(self: *DagBuilder, node: MerkleNode) ![]const u8 {
        // 1. Serialize (Mock serialization: we just use the data if leaf, or encode links)
        // For this task, we assume 'node.data' is the block content for leaves.
        // For parents, we should encode the links.
        
        // TODO: Real Protobuf/IPLD encoding. 
        // For now, if level > 0, we make a dummy buffer representing the links.
        // If level == 0, we use data.
        
        var bytes: []const u8 = undefined;
        var free_bytes = false;
        
        if (node.level == 0) {
            bytes = node.data;
        } else {
             // Rudimentary encoding for Parents so we get unique hashes
             var list = std.ArrayList(u8).init(self.allocator);
             for (node.links.items) |link| {
                 try list.writer().writeAll(link.cid);
                 try list.writer().writeAll(link.name);
             }
             bytes = try list.toOwnedSlice();
             free_bytes = true;
        }
        defer if (free_bytes) self.allocator.free(bytes);

        // 2. Create Block (Hash)
        const block = Block.new(bytes);
        
        // 3. Put to Store
        try self.store.put(block);
        
        // 4. Return CID (Hex string or Raw bytes? IPFS uses raw bytes in links, but strings in APIs)
        // Our DagLink uses []const u8 for CID. 
        // Block.cid is [32]u8.
        
        // We need to return a slice that fits into DagLink.cid.
        // Let's assume raw bytes for internal logic.
        return self.allocator.dupe(u8, &block.cid);
    }
};

test "DagBuilder build (Balanced) functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const test_path = "test_storage_dag_builder_balanced";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};
    
    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    
    var builder = DagBuilder{
        .allocator = allocator,
        .store = &engine,
        .layout = .Balanced,
    };
    
    const data = "This is a test string to be chunked and DAG-ified.";
    var fbs = std.io.fixedBufferStream(data);
    
    const cid = try builder.build(fbs.reader());
    defer allocator.free(cid);
    
    try testing.expect(cid.len > 0);
}

test "DagBuilder build (Linear) functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const test_path = "test_storage_dag_builder_linear";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};
    
    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    
    var builder = DagBuilder{
        .allocator = allocator,
        .store = &engine,
        .layout = .Linear,
    };
    
    const data = "This is a test string to be chunked and DAG-ified.";
    var fbs = std.io.fixedBufferStream(data);
    
    const cid = try builder.build(fbs.reader());
    defer allocator.free(cid);

    try testing.expect(cid.len > 0);
}