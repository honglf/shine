#!/bin/bash
set -e

# Build shine.framework (dynamic) for iOS and package as xcframework
#
# Uses dynamic linking to comply with LGPL: users can replace the
# framework with their own modified build of libshine.
#
# Requirements:
#   - Xcode and command line tools installed
#
# Usage:
#   ./build_ios.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output/ios"
IOS_DEPLOYMENT_TARGET="12.0"
FRAMEWORK_NAME="shine"
FRAMEWORK_VERSION="3.1.1"

if ! command -v xcrun &> /dev/null; then
    echo "Error: Xcode command line tools not found."
    echo "Install with: xcode-select --install"
    exit 1
fi

SOURCES=(
    src/lib/bitstream.c
    src/lib/huffman.c
    src/lib/l3bitstream.c
    src/lib/l3loop.c
    src/lib/l3mdct.c
    src/lib/l3subband.c
    src/lib/layer3.c
    src/lib/reservoir.c
    src/lib/tables.c
)

# Build a dylib for one (platform, arch) pair
# e.g. build_dylib iphoneos arm64 arm64-apple-ios12.0
build_dylib() {
    local PLATFORM=$1   # iphoneos / iphonesimulator
    local ARCH=$2       # arm64 / x86_64
    local TARGET=$3     # e.g. arm64-apple-ios12.0-simulator
    local LABEL="${PLATFORM}-${ARCH}"

    echo "  Compiling $LABEL ..."

    local BUILD_DIR="${SCRIPT_DIR}/build/ios-${LABEL}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
    local CC
    CC=$(xcrun --sdk "$PLATFORM" --find clang)

    local CFLAGS="-target $TARGET -isysroot $SDK_PATH"
    CFLAGS="$CFLAGS -funroll-loops -fno-exceptions -Wall -O2 -fsigned-char -fPIC -g"

    local LDFLAGS="-target $TARGET -isysroot $SDK_PATH"
    LDFLAGS="$LDFLAGS -dynamiclib -lm"
    LDFLAGS="$LDFLAGS -install_name @rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    LDFLAGS="$LDFLAGS -compatibility_version 1.0.0"
    LDFLAGS="$LDFLAGS -current_version ${FRAMEWORK_VERSION}"

    local OBJECTS=()
    for SRC in "${SOURCES[@]}"; do
        local OBJ_NAME
        OBJ_NAME=$(basename "$SRC" .c).o
        $CC $CFLAGS -I"$SCRIPT_DIR/src/lib" -c "$SCRIPT_DIR/$SRC" -o "$BUILD_DIR/$OBJ_NAME"
        OBJECTS+=("$BUILD_DIR/$OBJ_NAME")
    done

    $CC $LDFLAGS "${OBJECTS[@]}" -o "$BUILD_DIR/lib${FRAMEWORK_NAME}.dylib"

    # Save dSYM before stripping
    dsymutil "$BUILD_DIR/lib${FRAMEWORK_NAME}.dylib" -o "$BUILD_DIR/${FRAMEWORK_NAME}.dSYM"
    strip -x "$BUILD_DIR/lib${FRAMEWORK_NAME}.dylib"
}

# Package a .framework from one or more dylibs
# Usage: make_framework <platform> <dylib_paths...>
make_framework() {
    local PLATFORM=$1
    shift
    local DYLIBS=("$@")

    local FW_DIR="${SCRIPT_DIR}/build/ios-${PLATFORM}/${FRAMEWORK_NAME}.framework"
    rm -rf "$FW_DIR"
    mkdir -p "$FW_DIR/Headers"

    # If multiple dylibs, create fat binary with lipo
    if [ ${#DYLIBS[@]} -gt 1 ]; then
        lipo -create "${DYLIBS[@]}" -output "$FW_DIR/${FRAMEWORK_NAME}"
    else
        cp "${DYLIBS[0]}" "$FW_DIR/${FRAMEWORK_NAME}"
    fi

    cp "$SCRIPT_DIR/src/lib/layer3.h" "$FW_DIR/Headers/"

    cat > "$FW_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>org.savonet.${FRAMEWORK_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${FRAMEWORK_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${FRAMEWORK_VERSION}</string>
    <key>MinimumOSVersion</key>
    <string>${IOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST

    echo "Built: $FW_DIR"
}

rm -rf "$OUTPUT_DIR"

# 1. Build individual dylibs
echo ""
echo "========================================="
echo " Building dylibs"
echo "========================================="
build_dylib iphoneos       arm64  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
build_dylib iphonesimulator arm64  "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
build_dylib iphonesimulator x86_64 "x86_64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"

# 2. Package into .framework bundles
echo ""
echo "========================================="
echo " Creating frameworks"
echo "========================================="

echo "Device framework (arm64):"
make_framework iphoneos \
    "${SCRIPT_DIR}/build/ios-iphoneos-arm64/lib${FRAMEWORK_NAME}.dylib"

echo "Simulator framework (arm64 + x86_64):"
make_framework iphonesimulator \
    "${SCRIPT_DIR}/build/ios-iphonesimulator-arm64/lib${FRAMEWORK_NAME}.dylib" \
    "${SCRIPT_DIR}/build/ios-iphonesimulator-x86_64/lib${FRAMEWORK_NAME}.dylib"

# 3. Create xcframework
echo ""
echo "========================================="
echo " Creating xcframework"
echo "========================================="
mkdir -p "$OUTPUT_DIR"
xcodebuild -create-xcframework \
    -framework "${SCRIPT_DIR}/build/ios-iphoneos/${FRAMEWORK_NAME}.framework" \
    -framework "${SCRIPT_DIR}/build/ios-iphonesimulator/${FRAMEWORK_NAME}.framework" \
    -output "$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"

# 4. Collect dSYMs
echo ""
echo "========================================="
echo " Collecting dSYMs"
echo "========================================="
mkdir -p "$OUTPUT_DIR/dSYMs"
cp -R "${SCRIPT_DIR}/build/ios-iphoneos-arm64/${FRAMEWORK_NAME}.dSYM" \
    "$OUTPUT_DIR/dSYMs/${FRAMEWORK_NAME}-iphoneos-arm64.dSYM"
cp -R "${SCRIPT_DIR}/build/ios-iphonesimulator-arm64/${FRAMEWORK_NAME}.dSYM" \
    "$OUTPUT_DIR/dSYMs/${FRAMEWORK_NAME}-iphonesimulator-arm64.dSYM"
cp -R "${SCRIPT_DIR}/build/ios-iphonesimulator-x86_64/${FRAMEWORK_NAME}.dSYM" \
    "$OUTPUT_DIR/dSYMs/${FRAMEWORK_NAME}-iphonesimulator-x86_64.dSYM"

echo ""
echo "========================================="
echo " iOS build complete!"
echo "========================================="
echo "Output: $OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
echo ""
echo "LGPL compliance: this xcframework contains dynamic frameworks."
echo "Users can replace it with their own modified build of libshine."
echo ""
echo "Integration: drag shine.xcframework into your Xcode project,"
echo "ensure 'Embed & Sign' is selected in Frameworks settings."
