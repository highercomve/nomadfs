/*
 * nomadfs.h - C ABI for the NomadFS mobile shared library (libnomadfs.so).
 *
 * Rules:
 *  - Every export returns a numeric status (0 = ok) or a nullable handle /
 *    string; no Zig panics cross the boundary.
 *  - Strings are NUL-terminated; inputs are caller-owned, outputs from
 *    `nomadfs_put_file` must be released with `nomadfs_free`.
 *  - Calls on one handle are serialized internally; different handles can
 *    run in parallel.
 *  - `nomadfs_node_run` spawns its own thread; stop it (or free the node)
 *    before the host unloads the library.
 */
#ifndef NOMADFS_H
#define NOMADFS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOMADFS_OK 0
#define NOMADFS_INVALID_ARGUMENT 1
#define NOMADFS_STORAGE_DISABLED 2
#define NOMADFS_UNAVAILABLE 3
#define NOMADFS_FILE_TOO_LARGE 4
#define NOMADFS_NOT_FOUND 5
#define NOMADFS_INTERNAL_ERROR 9

typedef struct NomadNode NomadNode; /* opaque handle */

const char *nomadfs_version(void);

/* Creates a node from a nomadfs.conf path and wires storage, identity and
 * trust stores. Returns NULL on a bad or missing config. */
NomadNode *nomadfs_node_new(const char *config_path);

/* Frees the node, joins its threads and releases the config. */
void nomadfs_node_free(NomadNode *node);

/* Starts the TCP listener on a dedicated thread. Non-blocking; repeat calls
 * are no-ops. */
int nomadfs_node_run(NomadNode *node);

/* Signals the listener to stop and joins its thread. */
int nomadfs_node_stop(NomadNode *node);

/* Connects to comma-separated tcp://host:port bootstrap peers in a
 * background thread (the node keeps its own copy). */
int nomadfs_node_bootstrap(NomadNode *node, const char *urls_csv);

/* Chunks the file at `in_path` into the DAG, stores it locally, announces
 * the root CID and writes a 64-hex-character CID string.
 * Returns NULL when the write could not reach its provider-record quorum
 * (e.g. while offline); the blocks stay local either way. Free the CID with
 * nomadfs_free. */
char *nomadfs_put_file(NomadNode *node, const char *in_path);

/* Reassembles the file rooted at the 64-hex-character `cid` into
 * `out_path`, fetching missing blocks from holder records first, then from
 * the peers closest to the CID. Creates or truncates the output. */
int nomadfs_get_file(NomadNode *node, const char *cid, const char *out_path);

/* Writes this node's device ID (64 hex characters + NUL) into `out`. */
int nomadfs_node_device_id(NomadNode *node, unsigned char *out, size_t out_len);

/* Releases a string returned by nomadfs_put_file. */
void nomadfs_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* NOMADFS_H */
