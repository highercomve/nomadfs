package net.nomadfs;

/**
 * JNI binding over the NomadFS C ABI (libnomadfs.so via libnomadfs_jni.so).
 *
 * One instance wraps one node handle. All calls are serialized on the
 * native side, so calling from any Android thread is safe; the listener
 * thread lives until {@link #close()}.
 */
public final class NomadFs implements AutoCloseable {
    static {
        // The C ABI library is produced by Zig; see zig-out/lib.
        System.loadLibrary("nomadfs");
        System.loadLibrary("nomadfs_jni");
    }

    private long handle;

    private NomadFs(long handle) {
        this.handle = handle;
    }

    /** Returns a node for the given conf file, or null on a bad config. */
    public static NomadFs open(String configPath) {
        long handle = newNode(configPath);
        return handle == 0 ? null : new NomadFs(handle);
    }

    public synchronized int run() {
        return run(handle);
    }

    public synchronized int stop() {
        return stop(handle);
    }

    /**
     * Connects to comma-separated tcp://host:port bootstrap peers in the
     * background.
     */
    public synchronized int bootstrap(String urlsCsv) {
        return bootstrap(handle, urlsCsv);
    }

    /**
     * Stores the file and returns its root CID (64 hex characters), or
     * null while the provider record cannot reach its write quorum.
     * Blocks are kept locally either way; a retry announces them.
     */
    public synchronized String put(String inPath) {
        return put(handle, inPath);
    }

    /** Reassembles the file rooted at `cid` into `outPath`. */
    public synchronized int get(String cid, String outPath) {
        return get(handle, cid, outPath);
    }

    /** This node's device ID as 64 hex characters, or null on failure. */
    public synchronized String deviceId() {
        return deviceId(handle);
    }

    @Override
    public synchronized void close() {
        if (handle != 0) {
            free(handle);
            handle = 0;
        }
    }

    private static native long newNode(String configPath);
    private static native void free(long handle);
    private static native int run(long handle);
    private static native int stop(long handle);
    private static native int bootstrap(long handle, String urlsCsv);
    private static native String put(long handle, String inPath);
    private static native int get(long handle, String cid, String outPath);
    private static native String deviceId(long handle);
}
