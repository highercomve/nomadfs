/*
 * nomadfs.h - C ABI for the NomadFS mobile shared library (libnomadfs.so).
 *
 * Rules:
 *  - Every export returns a numeric status (0 = ok) or a nullable handle /
 *    string; no Zig panics cross the boundary.
 *  - Strings are NUL-terminated; inputs are caller-owned, returned
 *    strings must be released with `nomadfs_free`.
 *  - Calls on one handle are serialized internally; different handles can
 *    run in parallel.
 *  - `nomadfs_node_run` spawns its own thread; stop it (or free the node)
 *    before the host unloads the library.
 */
#ifndef NOMADFS_H
#define NOMADFS_H

#include <stdint.h>

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum reassembled file size: 4 GiB. */
#define NOMADFS_MAX_FILE_BYTES 4294967296ULL

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

/* Waits for in-flight calls, joins threads and releases the config.
 * Do not reuse the handle after free; its address may be reused. */
void nomadfs_node_free(NomadNode *node);

/* Binds the TCP listener before returning; accepts run in the background.
 * Repeat calls while running are no-ops. After stop or a startup failure,
 * run returns NOMADFS_UNAVAILABLE; create a new node to restart. */
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
 * the peers closest to the CID. Creates or truncates the output.
 * Rejects malformed CIDs and files larger than NOMADFS_MAX_FILE_BYTES. */
int nomadfs_get_file(NomadNode *node, const char *cid, const char *out_path);

/* Writes this node's device ID (64 hex characters + NUL) into `out`. */
int nomadfs_node_device_id(NomadNode *node, unsigned char *out, size_t out_len);

/* The read cache (blocks fetched from other devices only to be read,
 * evicted least recently used first): bytes, blocks and the limit in bytes
 * (0 = none). Any output pointer may be NULL. */
int nomadfs_cache_info(NomadNode *node, uint64_t *out_bytes, uint64_t *out_blocks, uint64_t *out_limit);

/* Empties the read cache; the bytes freed go to `out_freed` (may be NULL).
 * Blocks this device keeps (its writes, backups) are not touched. */
int nomadfs_cache_clear(NomadNode *node, uint64_t *out_freed);

/* Sets the running node's read cache limit in MiB; 0 removes the limit. */
int nomadfs_cache_set_limit(NomadNode *node, uint64_t limit_mb);

/* The photos timeline: every picture and film in the swarm folder below
 * `folder` (NULL or "": all of it), newest first, as JSON:
 *   {"generation":N,"total":N,"photos":N,"videos":N,
 *    "mtimes":[seconds,...],"folders":[{"path":"...","count":N},...]}
 * `mtimes` has every item's modified time in the timeline's order;
 * `folders` the folders they are in, two levels deep. NULL on failure.
 * Free the string with nomadfs_free. */
char *nomadfs_photos_index_json(NomadNode *node, const char *folder);

/* `count` items (500 at most) of that timeline from `start`, as JSON:
 *   {"generation":N,"total":N,"items":[{"index":N,"path":"...",
 *    "name":"...","cid":"hex","author":"hex","size":N,"mtime":seconds,
 *    "kind":"photo|video|heic|raw","thumb":"ready|none|unknown"}]}
 * `generation` is the index's: once the folder changed since then the
 * answer is {"error":"Stale"} and the index must be asked for again; 0
 * takes the timeline as it is now. NULL on any other failure. Free the
 * string with nomadfs_free. */
char *nomadfs_photos_json(NomadNode *node, const char *folder, uint64_t generation, uint32_t start, uint32_t count);

/* Writes the thumbnail (a small JPEG, 320 pixels on its long edge) of the
 * swarm folder file with the 64-hex-character content ID `cid_hex` to
 * `out_path`, created or truncated. `author_hex` is the item's "author"
 * in the photos JSON (NULL when unknown). The thumbnail is made from the
 * file when all of it is on this device, and kept; the file itself is
 * never downloaded for it.
 *   NOMADFS_OK           written
 *   NOMADFS_NOT_FOUND    none can be made of this file (show a placeholder)
 *   NOMADFS_UNAVAILABLE  being made, or the file isn't on this device:
 *                        ask again later */
int nomadfs_thumbnail(NomadNode *node, const char *cid_hex, const char *author_hex, const char *out_path);

/* Releases a string returned by this API. */
void nomadfs_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* NOMADFS_H */
