package net.nomadfs.harness;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.util.Arrays;

import net.nomadfs.NomadFs;

/**
 * Runs the full lifecycle a mobile host would follow, on-device, and
 * reports one terminal line: "NOMADFS-HARNESS: PASS" or "... FAIL".
 *
 * Drive it with:
 *   adb install -r build/harness.apk
 *   adb shell am instrument -w net.nomadfs.harness/net.nomadfs.harness.NomadFsInstrumentation
 */
public final class NomadFsInstrumentation extends Instrumentation {
    private static final String TAG = "NomadFsHarness";
    private static final String SWARM_KEY =
        "4090e76685f6f17bbe398fd4b2f12945168aaaa64107b7e57fe72dffa2c9436e";

    private int checks;

    @Override
    public void onStart() {
        int code;
        try {
            code = runHarness();
        } catch (Throwable t) {
            Log.e(TAG, "harness crashed", t);
            code = 3;
        }
        report(code);
    }

    private int runHarness() throws Exception {
        Context ctx = getTargetContext();
        File base = new File(ctx.getFilesDir(), "harness");
        rmrf(base);
        assertThat(base.mkdirs(), "mkdirs filesDir/harness");

        File storageA = new File(base, "data_a");
        File storageB = new File(base, "data_b");
        File keyA = new File(base, "node_a.key");
        File keyB = new File(base, "node_b.key");
        File inPath = new File(base, "payload.bin");
        File outPath = new File(base, "out.bin");

        final int payloadLen = 200_000;
        byte[] payload = new byte[payloadLen];
        // Deterministic pseudo-random content: any 32 KiB-scale fades that
        // would hit the chunker's boundary cases are still covered.
        long state = 1234567;
        for (int i = 0; i < payloadLen; i++) {
            state = state * 6364136223846793005L + 1442695040888963407L;
            payload[i] = (byte) (state >>> 33);
        }
        write(inPath, payload);

        String confA = buildConfig(base, storageA, keyA, 13460);
        String confB = buildConfig(base, storageB, keyB, 13461);
        write(new File(base, "a.conf"), confA);
        write(new File(base, "b.conf"), confB);

        // 1. Lifecycle on a real ART runtime.
        NomadFs a = NomadFs.open(base + "/a.conf");
        NomadFs b = NomadFs.open(base + "/b.conf");
        assertThat(a != null && b != null, "nodes opened");
        assertEquals(0, a.run(), "node A run()");
        assertEquals(0, b.run(), "node B run()");
        String deviceA = a.deviceId();
        String deviceB = b.deviceId();
        assertThat(deviceA != null && deviceB != null && deviceA.length() == 64 &&
                   !deviceA.equals(deviceB), "distinct device ids");
        Log.i(TAG, "device A " + deviceA);

        // 2. B joins the swarm by bootstrapping against its own peer.
        assertEquals(0, b.bootstrap("tcp://127.0.0.1:13460"), "bootstrap");

        // 3. Cross-node transfer: put on B, get on A (A fetches every
        //    missing block from B over GET_BLOCK and verifies each CID).
        String cid = waitForPut(b, inPath);
        assertThat(cid != null && cid.length() == 64, "put returned a 64-hex CID");
        Log.i(TAG, "root cid " + cid);

        assertEquals(0, a.get(cid, outPath.getPath()), "get on the other node");
        assertThat(Arrays.equals(payload, read(outPath)), "byte-identical round trip");

        // 4. Idempotent second read of the same root.
        File out2 = new File(base, "out2.bin");
        assertEquals(0, a.get(cid, out2.getPath()), "second get");
        assertThat(Arrays.equals(payload, read(out2)), "idempotent read");

        // 5. Clean shutdown of both nodes.
        assertEquals(0, b.stop(), "node B stop()");
        assertEquals(0, a.stop(), "node A stop()");
        b.close();
        a.close();
        return 0;
    }

    /** Provider-record quorum needs the DHT to settle after bootstrap. */
    private String waitForPut(NomadFs node, File inPath) throws InterruptedException {
        for (int attempt = 0; attempt < 10; attempt++) {
            Thread.sleep(500);
            String cid = node.put(inPath.getPath());
            if (cid != null) return cid;
            Log.w(TAG, "put quorum not reached yet (" + attempt + ")");
        }
        return null;
    }

    private String buildConfig(File base, File storage, File key, int port) {
        return "[node]\n" +
            "nickname = \"harness\"\n" +
            "swarm_key = \"" + SWARM_KEY + "\"\n" +
            "key_path = \"" + key.getPath() + "\"\n" +
            "\n[storage]\n" +
            "enabled = true\n" +
            "storage_path = \"" + storage.getPath() + "\"\n" +
            "\n[network]\n" +
            "port = " + port + "\n" +
            "transport = \"tcp\"\n" +
            "upnp_enabled = false\n" +
            "enable_mdns = false\n" +
            "bootstrap_peers = []\n";
    }

    private void rmrf(File path) {
        if (!path.exists()) return;
        File[] children = path.listFiles();
        if (children != null) for (File c : children) rmrf(c);
        path.delete();
    }

    private void assertEquals(int expected, int actual, String what) {
        assertThat(expected == actual, what + " -> " + actual);
    }

    private void assertThat(boolean ok, String what) {
        checks++;
        if (!ok) {
            throw new IllegalStateException("check failed: " + what);
        }
        Log.i(TAG, "check ok: " + what + " (" + checks + ")");
    }

    private void write(File path, byte[] data) throws Exception {
        try (OutputStream out = new FileOutputStream(path)) {
            out.write(data);
        }
    }

    private void write(File path, String text) throws Exception {
        write(path, text.getBytes("UTF-8"));
    }

    private byte[] read(File path) throws Exception {
        byte[] data = new byte[(int) path.length()];
        try (BufferedInputStream in = new BufferedInputStream(new FileInputStream(path))) {
            int off = 0;
            while (off < data.length) {
                int n = in.read(data, off, data.length - off);
                if (n <= 0) throw new IllegalStateException("short read of " + path);
                off += n;
            }
        }
        return data;
    }

    private void report(int code) {
        String status = code == 0 ? "PASS" : "FAIL(" + code + ")";
        Log.e(TAG, "NOMADFS-HARNESS: " + status);
        Bundle results = new Bundle();
        results.putString("nomadfs_harness_status", status);
        finish(0, results);
    }
}
