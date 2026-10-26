/* Anchors the header-only CNomadFs target so SwiftPM emits an object for
 * it; all real behaviour lives in the zig-built libnomadfs.so. */
#include "include/nomadfs.h"

const char *nomadfs_swift_shim_version(void) {
    return nomadfs_version();
}
