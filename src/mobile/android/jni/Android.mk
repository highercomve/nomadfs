# Compiles the JNI bridge against the zig-built libnomadfs.so.
#
#   $ zig build -Dtarget=aarch64-linux-android      # (see gen-libc.sh)
#   $ ANDROID_NDK_HOME=... ndk-build   # from src/mobile/android
#
# Output: libs/arm64-v8a/libnomadfs_jni.so. Copy both .so files from
# zig-out/lib and libs/arm64-v8a into your app's jniLibs directory.

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
# jni -> android -> mobile -> repo root.
NOMADFS_DIR := $(abspath $(LOCAL_PATH)/../../../..)
ZIG_LIB_DIR := $(NOMADFS_DIR)/zig-out/lib
LOCAL_MODULE := nomadfs_jni
LOCAL_SRC_FILES := NomadFsJNI.c
LOCAL_C_INCLUDES := $(NOMADFS_DIR)/src/mobile
LOCAL_LDLIBS := -L$(ZIG_LIB_DIR) -lnomadfs
include $(BUILD_SHARED_LIBRARY)
