//
//  NomadFs.swift
//  Swift wrapper over the NomadFS C ABI.
//
//  A `NomadFs` value owns one node handle (config, storage, identity,
//  trust store). All native calls are serialized internally, so calling
//  from any thread or actor is safe; the listener thread lives until
//  deinit/`close()`.
//
import CNomadFs

public final class NomadFs {
    private var handle: OpaquePointer?

    /// Opens a node from a `nomadfs.conf` path; returns nil on a bad or
    /// missing config.
    public static func open(configPath: String) -> NomadFs? {
        guard let handle = configPath.withCString(nomadfs_node_new) else {
            return nil
        }
        return NomadFs(handle: handle)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    /// Starts the TCP listener on a dedicated native thread. Non-blocking.
    @discardableResult
    public func run() -> Int32 {
        nomadfs_node_run(handle)
    }

    /// Signals the listener to stop and joins its thread.
    @discardableResult
    public func stop() -> Int32 {
        nomadfs_node_stop(handle)
    }

    /// Connects to comma-separated `tcp://host:port` bootstrap peers.
    @discardableResult
    public func bootstrap(urlsCsv: String) -> Int32 {
        urlsCsv.withCString { nomadfs_node_bootstrap(handle, $0) }
    }

    /// Stores the file; returns its root CID (64 hex characters) or nil
    /// while offline (blocks stay local; retry announces).
    public func put(inPath: String) -> String? {
        inPath.withCString { path -> String? in
            guard let cid = nomadfs_put_file(handle, path) else { return nil }
            defer { nomadfs_free(cid) }
            return String(cString: cid)
        }
    }

    /// Reassembles the file rooted at `cid` into `outPath`.
    @discardableResult
    public func get(cid: String, outPath: String) -> Int32 {
        cid.withCString { cidPtr in
            outPath.withCString { outPtr in
                nomadfs_get_file(handle, cidPtr, outPtr)
            }
        }
    }

    /// This node's device ID as 64 hex characters, or nil on failure.
    public func deviceId() -> String? {
        var buffer = [UInt8](repeating: 0, count: 65)
        // The C call writes 64 hex bytes; the length-1 room covers the NUL.
        guard nomadfs_node_device_id(handle, &buffer, buffer.count) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Releases the node handle; further calls are invalid afterwards.
    public func close() {
        if let handle = handle {
            nomadfs_node_free(handle)
            self.handle = nil
        }
    }
}
