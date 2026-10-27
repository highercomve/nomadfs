/* Cross-architecture probe: a host (x86_64 zig-built lib) talks to an
 * Android device (arm64) over the LAN with the SAME C ABI:
 *
 *   host-probe put <conf> <payload_in>          -> prints CID
 *   host-probe get <conf> <peer> <cid> <out> <len> -> byte-compares on host
 */
#include "nomadfs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: host-probe <mode> <conf> ...\n"); return 2; }
    const char *mode = argv[1];

    NomadNode *node = nomadfs_node_new(argv[2]);
    if (!node) { printf("PROBE-FAIL node_new\n"); return 1; }
    if (nomadfs_node_run(node) != 0) { printf("PROBE-FAIL run\n"); return 1; }

    if (strcmp(mode, "put") == 0) {
        char *cid = nomadfs_put_file(node, argv[3]);
        if (!cid) { printf("PROBE-FAIL put\n"); return 1; }
        printf("PROBE-CID %s\n", cid);
        nomadfs_free(cid);
        /* serve for a while; the peer fetches its blocks from us */
        sleep(60);
        nomadfs_node_free(node);
        return 0;
    }

    if (strcmp(mode, "get") == 0) {
        if (argc < 7) { printf("usage: host-probe get <conf> <peer> <cid> <out> <len>\n"); return 2; }
        const char *peer = argv[3];
        const char *cid = argv[4];
        const char *out = argv[5];
        int len = atoi(argv[6]);
        if (nomadfs_node_bootstrap(node, peer) != 0) { printf("PROBE-FAIL bootstrap\n"); return 1; }
        sleep(2);

        if (nomadfs_get_file(node, cid, out) != 0) { printf("PROBE-FAIL get\n"); return 1; }
        /* The payload is deterministic: regenerate it and compare. */
        unsigned long state = 1234567;
        FILE *f = fopen(out, "rb");
        if (!f) { printf("PROBE-FAIL open out\n"); return 1; }
        for (int i = 0; i < len; i++) {
            int c = fgetc(f);
            if (c == EOF) { printf("PROBE-FAIL short out\n"); return 1; }
            state = state * 6364136223846793005UL + 1442695040888963407UL;
            unsigned char b = (unsigned char)((state >> 33) & 0xff);
            if ((unsigned char)c != b) { printf("PROBE-FAIL byte %d (%02x != %02x)\n", i, (unsigned char)c, b); return 1; }
        }
        fclose(f);
        printf("PROBE-PASS\n");
        return 0;
    }
    printf("PROBE-FAIL unknown mode %s\n", mode);
    return 2;
}
