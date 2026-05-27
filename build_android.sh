#!/bin/bash
set -e

# Build libshine.so for Android (arm64-v8a, armeabi-v7a, x86, x86_64)
#
# Requirements:
#   - Android NDK installed
#   - Set ANDROID_NDK_HOME (or NDK_HOME) environment variable
#
# Usage:
#   ./build_android.sh              # build all ABIs
#   ./build_android.sh arm64-v8a    # build specific ABI

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output/android"
MIN_SDK_VERSION=21

# Detect NDK path
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -n "$NDK_HOME" ]; then
        ANDROID_NDK_HOME="$NDK_HOME"
    elif [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/ndk" ]; then
        # Use the latest NDK version in ANDROID_HOME/ndk/
        ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "Error: Android NDK not found."
    echo "Set ANDROID_NDK_HOME or NDK_HOME environment variable."
    exit 1
fi

echo "Using NDK: $ANDROID_NDK_HOME"

CMAKE_TOOLCHAIN="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
if [ ! -f "$CMAKE_TOOLCHAIN" ]; then
    echo "Error: CMake toolchain not found at $CMAKE_TOOLCHAIN"
    exit 1
fi

ALL_ABIS="arm64-v8a armeabi-v7a x86 x86_64"
BUILD_ABIS="${@:-$ALL_ABIS}"

rm -rf "$OUTPUT_DIR"

for ABI in $BUILD_ABIS; do
    echo ""
    echo "========================================="
    echo " Building for $ABI"
    echo "========================================="

    BUILD_DIR="${SCRIPT_DIR}/build/android-${ABI}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-${MIN_SDK_VERSION}" \
        -DANDROID_STL=none \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo

    cmake --build "$BUILD_DIR" --config RelWithDebInfo -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

    # Extract debug symbols, then strip
    TOOLCHAIN_PREFIX="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64/bin/llvm"
    mkdir -p "$OUTPUT_DIR/$ABI"
    mkdir -p "$OUTPUT_DIR/symbols/$ABI"
    cp "$BUILD_DIR"/libshine.so "$OUTPUT_DIR/$ABI/"
    "${TOOLCHAIN_PREFIX}-objcopy" --only-keep-debug "$OUTPUT_DIR/$ABI/libshine.so" "$OUTPUT_DIR/symbols/$ABI/libshine.so.sym"
    "${TOOLCHAIN_PREFIX}-strip" --strip-unneeded "$OUTPUT_DIR/$ABI/libshine.so"
    "${TOOLCHAIN_PREFIX}-objcopy" --add-gnu-debuglink="$OUTPUT_DIR/symbols/$ABI/libshine.so.sym" "$OUTPUT_DIR/$ABI/libshine.so"
done

# Copy header
mkdir -p "$OUTPUT_DIR/include"
cp "$SCRIPT_DIR/src/lib/layer3.h" "$OUTPUT_DIR/include/"

echo ""
echo "========================================="
echo " Android build complete!"
echo "========================================="
echo "Output: $OUTPUT_DIR"
echo ""
find "$OUTPUT_DIR" -type f | sort
