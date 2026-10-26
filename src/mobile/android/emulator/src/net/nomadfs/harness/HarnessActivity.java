package net.nomadfs.harness;

import android.app.Activity;
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
 * Headless harness: runs the full binding flow inside ART's app namespace
 * (native libs load through the app's classloader namespace, below the
 * instrumentation path) and logs one terminal line: NOMADFS-HARNESS: PASS
 * or ... FAIL.
 *
 *   adb install -r harness.apk
 *   adb shell am start -W -n net.nomadfs.harness/net.nomadfs.harness.HarnessActivity
 */
public final class HarnessActivity extends Activity {
    private static final String TAG = "NomadFsHarness";
    private static final String SWARM_KEY =
        "4090e76685f6f17bbe398fd4b2f12945168aaaa64107b7e57fe72dffa2c9436e";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        final Activity self = this;
        new Thread(() -> {
            int code;
            try {
                runHarness();
                code = 0;
            } catch (Throwable t) {
                Log.e(TAG, "harness failed", t);
                code = 3;
            }
            Log.println(Log.INFO, TAG, "NOMADFS-HARNESS: " + (code == 0 ? "PASS" : "FAIL(" + code + ")"));
            finish();
            self.finishAffinity();
        }, "nomadfs-harness").start();
    }

    private static final int PORT_A = 13460;
    private static final int PORT_B = 13461;

    private void runHarness() throws Exception {
        File base = new File(getFilesDir(), "harness");
        rmrf(base);
        assertThat(base.mkdirs(), "mkdirs filesDir/harness");
        File storageA = new File(base, "data_a");
        File storageB = new File(base, "data_b");
        // The device identity always lives next to key_path's directory, so
        // the two nodes need different directories to differ.
        File keyA = new File(base, "key_a/node.key");
        File keyB = new File(base, "key_b/node.key");
        assertThat(new File(base, "key_a").mkdirs() && new File(base, "key_b").mkdirs(), "key dirs");
        File inPath = new File(base, "payload.bin");
        File outPath = new File(base, "out.bin");
        File out2 = new File(base, "out2.bin");

        final int payloadLen = 200_000;
        byte[] payload = new byte[payloadLen];
        long state = 1234567;
        for (int i = 0; i < payloadLen; i++) {
            state = state * 6364136223846793005L + 1442695040888963407L;
            payload[i] = (byte) (state >>> 33);
        }
        write(inPath, payload);
        write(new File(base, "a.conf"), buildConfig(storageA, keyA, PORT_A));
        write(new File(base, "b.conf"), buildConfig(storageB, keyB, PORT_B));

        // 1. Lifecycle inside the app namespace (both native libs load from
        //    the APK's lib/x86_64 through the app classloader namespace).
        NomadFs a = NomadFs.open(base + "/a.conf");
        NomadFs b = NomadFs.open(base + "/b.conf");
        assertThat(a != null && b != null, "nodes opened");
        assertThat(a.run() == 0 && b.run() == 0, "both listeners running");
        assertThat(a.deviceId() != null && b.deviceId() != null &&
                   !a.deviceId().equals(b.deviceId()), "distinct device ids");
        Log.d(TAG, "node A device: " + a.deviceId());

        // 2. B joins the swarm through its own peer.
        assertThat(b.bootstrap("tcp://127.0.0.1:" + PORT_A) == 0, "bootstrap");

        // 3. Cross-node transfer: put on B, get on A; A must fetch every
        //    missing block from B, verifying it against the CID.
        String cid = waitForPut(b, inPath);
        assertThat(cid != null && cid.length() == 64, "put returned a 64-hex CID");
        Log.d(TAG, "root cid: " + cid);

        assertThat(a.get(cid, outPath.getPath()) == 0, "get on the other node");
        assertThat(Arrays.equals(payload, read(outPath)), "byte-identical round trip");
        assertThat(a.get(cid, out2.getPath()) == 0, "idempotent second get");
        assertThat(Arrays.equals(payload, read(out2)), "idempotent read");

        // 4. Both listeners shut down cleanly.
        assertThat(b.stop() == 0 && a.stop() == 0, "both stopped");
        b.close();
        a.close();
    }

    /** Provider-record quorum needs the DHT to settle after bootstrap. */
    private String waitForPut(NomadFs node, File inPath) throws InterruptedException {
        for (int attempt = 0; attempt < 10; attempt++) {
            String cid = node.put(inPath.getPath());
            if (cid != null) return cid;
            Log.d(TAG, "put quorum not reached yet (" + attempt + ")");
            Thread.sleep(500);
        }
        return null;
    }

    private String buildConfig(File storage, File key, int port) {
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

    private void assertThat(boolean ok, String what) {
        if (!ok) throw new IllegalStateException("check failed: " + what);
        Log.i(TAG, "check ok: " + what);
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
}
