package net.nomadfs.harness;

import android.app.Activity;
import android.content.Intent;
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
 * One node driven by adb, for cross-device transfers (phone x emulator,
 * arm64 x x86_64 interop):
 *
 *   mode=serve : open node, bootstrap to `peer` if set, stay alive until
 *                force-stopped (the peer needs us to serve blocks).
 *   mode=put   : same, then store the deterministic payload of
 *                `payloadLen` bytes and keep serving.
 *   mode=get   : bootstrap, then reassemble `cid` into `outPath` and
 *                byte-compare against the same deterministic payload.
 *
 * Every run logs "NOMADFS-REMOTE: READY ...", then either keeps running
 * (serve/put) or "DONE mode=<m> status=<s> cid=<c>".
 */
public final class RemoteNodeActivity extends Activity {
    private static final String TAG = "NomadFsRemote";
    private android.os.ParcelFileDescriptor stderrFd;

    private void redirectStderr(File path) {
        try {
            stderrFd = android.os.ParcelFileDescriptor.open(
                path, android.os.ParcelFileDescriptor.MODE_CREATE |
                      android.os.ParcelFileDescriptor.MODE_APPEND |
                      android.os.ParcelFileDescriptor.MODE_READ_WRITE);
            android.system.Os.dup2(stderrFd.getFileDescriptor(), 2);
        } catch (Throwable t) {
            Log.w(TAG, "stderr redirect failed", t);
        }
    }

    private static final String SWARM_KEY =
        "4090e76685f6f17bbe398fd4b2f12945168aaaa64107b7e57fe72dffa2c9436e";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // The zig stack reports progress on stderr; route it into a file so
        // adb can read it (run-as net.omadfs.harness cat files/stderr.log).
        redirectStderr(new File(getFilesDir(), "stderr.log"));
        new Thread(() -> {
            int code;
            String cid = "";
            try {
                runRemote();
                code = 0;
            } catch (Throwable t) {
                Log.e(TAG, "remote failed", t);
                code = 3;
            }
            Log.println(Log.INFO, TAG, "NOMADFS-REMOTE: DONE mode="
                + getIntent().getStringExtra("mode") + " status=" + code + " cid=" + cid);
        }, "nomadfs-remote").start();
    }

    private void runRemote() throws Exception {
        Intent in = getIntent();
        String mode = in.getStringExtra("mode");
        String peer = in.getStringExtra("peer");
        int port = Integer.parseInt(in.getStringExtra("port"));

        File base = new File(getFilesDir(), "remote");
        rmrf(base);
        assertThat(base.mkdirs(), "mkdirs");
        File storage = new File(base, "data");
        File key = new File(base, "keys/node.key");
        assertThat(new File(base, "keys").mkdirs(), "key dirs");
        write(new File(base, "nomadfs.conf"), buildConfig(storage, key, port));

        NomadFs node = NomadFs.open(new File(base, "nomadfs.conf").getPath());
        assertThat(node != null, "node opened");
        assertThat(node.run() == 0, "listener running");
        if (peer != null) assertThat(node.bootstrap(peer) == 0, "bootstrap");
        Log.println(Log.INFO, TAG, "NOMADFS-REMOTE: READY mode=" + mode
            + " device=" + node.deviceId());

        switch (mode) {
            case "serve" -> {
                // Stay alive until the orchestrator force-stops us.
                Thread.currentThread().join();
            }
            case "put" -> {
                int payloadLen = Integer.parseInt(in.getStringExtra("payloadLen"));
                File inPath = new File(base, "payload.bin");
                writePayload(inPath, payloadLen);
                String thisCid = waitForPut(node, inPath);
                if (thisCid == null) throw new IllegalStateException("put quorum missed");
                Log.println(Log.INFO, TAG, "NOMADFS-REMOTE CID: " + thisCid);
                // Keep serving: the receiver fetches its missing blocks now.
                Thread.currentThread().join();
            }
            case "get" -> {
                String thisCid = in.getStringExtra("cid");
                File outPath = new File(base, "out.bin");
                assertThat(node.get(thisCid, outPath.getPath()) == 0, "get status");

                // The payload is deterministic, so both ends can regenerate
                // it and compare byte-for-byte on-device.
                File expected = new File(base, "expected.bin");
                writePayload(expected, Integer.parseInt(in.getStringExtra("payloadLen")));
                assertThat(Arrays.equals(read(outPath), read(expected)), "byte-identical round trip");

                assertThat(node.stop() == 0, "stop");
                node.close();
                finishAffinity();
                return;
            }
            default -> throw new IllegalStateException("unknown mode " + mode);
        }
    }

    /** Provider-record quorum needs the DHT to settle after bootstrap. */
    private String waitForPut(NomadFs node, File inPath) throws InterruptedException {
        for (int attempt = 0; attempt < 10; attempt++) {
            String thisCid = node.put(inPath.getPath());
            if (thisCid != null) return thisCid;
            Log.d(TAG, "put quorum not reached yet (" + attempt + ")");
            Thread.sleep(500);
        }
        return null;
    }

    private void writePayload(File path, int len) throws Exception {
        byte[] data = new byte[len];
        long state = 1234567;
        for (int i = 0; i < len; i++) {
            state = state * 6364136223846793005L + 1442695040888963407L;
            data[i] = (byte) (state >>> 33);
        }
        try (OutputStream out = new FileOutputStream(path)) {
            out.write(data);
        }
    }

    private String buildConfig(File storage, File key, int port) {
        return "[node]\n" +
            "nickname = \"remote\"\n" +
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
            "bootstrap_peers = []\n" +
            "write_quorum = 0\n" +
            "replicas = 0\n";
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

    private void write(File path, String text) throws Exception {
        try (OutputStream out = new FileOutputStream(path)) {
            out.write(text.getBytes("UTF-8"));
        }
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
