# Compiles the JNI bridge against the per-ABI zig-built libnomadfs.so.
#
#   $ for abi in arm64-v8a x86_64; do
#       NOMADFS_ANDROID_ABI=$abi ./gen-libc.sh lib -p zig-out/android/$abi
#     done
#   $ ANDROID_NDK_HOME=... ndk-build    # from src/mobile/android
#
# Output: libs/<abi>/libnomadfs.so + libnomadfs_jni.so for every ABI the
# prebuilt tree provides. Copy libs/<abi>/* into your app's jniLibs/<abi>/.
# Chromebooks and Googlebooks run Android in ARC VM: x86_64 on Intel hosts,
# arm64-v8a on Snapdragon hosts - ship both.

LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
# jni -> android -> mobile -> repo root.
NOMADFS_DIR := $(abspath $(LOCAL_PATH)/../../../..)
ZIG_ANDROID_DIR := $(NOMADFS_DIR)/zig-out/android

# One prebuilt module per zig-built ABI; ndk-build picks the branch that
# matches $(TARGET_ARCH_ABI), and nomadfs_jni links its exported lib.
ifeq ($(TARGET_ARCH_ABI),arm64-v8a)
include $(CLEAR_VARS)
LOCAL_MODULE := nomadfs
LOCAL_SRC_FILES := $(ZIG_ANDROID_DIR)/arm64-v8a/lib-android/libnomadfs.so
LOCAL_EXPORT_C_INCLUDES := $(NOMADFS_DIR)/src/mobile
include $(PREBUILT_SHARED_LIBRARY)
else ifeq ($(TARGET_ARCH_ABI),x86_64)
include $(CLEAR_VARS)
LOCAL_MODULE := nomadfs
LOCAL_SRC_FILES := $(ZIG_ANDROID_DIR)/x86_64/lib-android/libnomadfs.so
LOCAL_EXPORT_C_INCLUDES := $(NOMADFS_DIR)/src/mobile
include $(PREBUILT_SHARED_LIBRARY)
endif

include $(CLEAR_VARS)
LOCAL_MODULE := nomadfs_jni
LOCAL_SRC_FILES := NomadFsJNI.c
LOCAL_SHARED_LIBRARIES := nomadfs
include $(BUILD_SHARED_LIBRARY)
