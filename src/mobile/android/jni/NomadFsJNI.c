//! JNI bridge for the NomadFS C ABI.
//!
//! Compiled with the Android NDK (see Android.mk) and linked against the
//! zig-built `libnomadfs.so`. Every Java surface in
//! `java/net/nomadfs/NomadFs.java` maps 1:1 to an entry here; lifecycle
//! ownership stays in Java: a handle acquired via newNode is released by
//! exactly one free() call from NomadFs.close().

#include <jni.h>
#include <stdint.h>
#include "nomadfs.h"

static NomadNode *asNode(jlong handle) {
    return (NomadNode *)(intptr_t)handle;
}

JNIEXPORT jlong JNICALL
Java_net_nomadfs_NomadFs_newNode(JNIEnv *env, jclass _cls, jstring j_path) {
    (void)_cls;
    const char *path = (*env)->GetStringUTFChars(env, j_path, NULL);
    if (path == NULL) return 0;
    NomadNode *node = nomadfs_node_new(path);
    (*env)->ReleaseStringUTFChars(env, j_path, path);
    return (jlong)(intptr_t)node;
}

JNIEXPORT void JNICALL
Java_net_nomadfs_NomadFs_free(JNIEnv *env, jclass _cls, jlong handle) {
    (void)env;
    (void)_cls;
    nomadfs_node_free(asNode(handle));
}

JNIEXPORT jint JNICALL
Java_net_nomadfs_NomadFs_run(JNIEnv *env, jclass _cls, jlong handle) {
    (void)env;
    (void)_cls;
    return nomadfs_node_run(asNode(handle));
}

JNIEXPORT jint JNICALL
Java_net_nomadfs_NomadFs_stop(JNIEnv *env, jclass _cls, jlong handle) {
    (void)env;
    (void)_cls;
    return nomadfs_node_stop(asNode(handle));
}

JNIEXPORT jint JNICALL
Java_net_nomadfs_NomadFs_bootstrap(JNIEnv *env, jclass _cls, jlong handle, jstring j_urls) {
    (void)_cls;
    const char *urls = (*env)->GetStringUTFChars(env, j_urls, NULL);
    if (urls == NULL) return 1001;
    int rc = nomadfs_node_bootstrap(asNode(handle), urls);
    (*env)->ReleaseStringUTFChars(env, j_urls, urls);
    return rc;
}

JNIEXPORT jstring JNICALL
Java_net_nomadfs_NomadFs_put(JNIEnv *env, jclass _cls, jlong handle, jstring j_path) {
    (void)_cls;
    const char *path = (*env)->GetStringUTFChars(env, j_path, NULL);
    if (path == NULL) return NULL;
    char *cid = nomadfs_put_file(asNode(handle), path);
    (*env)->ReleaseStringUTFChars(env, j_path, path);
    if (cid == NULL) return NULL;

    jstring result = (*env)->NewStringUTF(env, cid);
    nomadfs_free(cid);
    return result;
}

JNIEXPORT jint JNICALL
Java_net_nomadfs_NomadFs_get(JNIEnv *env, jclass _cls, jlong handle, jstring j_cid, jstring j_out) {
    (void)_cls;
    const char *cid = (*env)->GetStringUTFChars(env, j_cid, NULL);
    if (cid == NULL) return 1001;
    const char *out = (*env)->GetStringUTFChars(env, j_out, NULL);
    if (out == NULL) {
        (*env)->ReleaseStringUTFChars(env, j_cid, cid);
        return 1001;
    }
    int rc = nomadfs_get_file(asNode(handle), cid, out);
    (*env)->ReleaseStringUTFChars(env, j_out, out);
    (*env)->ReleaseStringUTFChars(env, j_cid, cid);
    return rc;
}

JNIEXPORT jstring JNICALL
Java_net_nomadfs_NomadFs_deviceId(JNIEnv *env, jclass _cls, jlong handle) {
    (void)_cls;
    unsigned char id[65];
    if (nomadfs_node_device_id(asNode(handle), id, sizeof(id)) != 0) return NULL;
    id[64] = 0;
    return (*env)->NewStringUTF(env, (const char *)id);
}
