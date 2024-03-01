#!/bin/bash

# Enable strict error checking and exit on error or pipe failure
set -o errexit -o pipefail

# Define a function to print an error message and exit
print_error() {
    echo "$1" >&2
    exit 1
}

# Get the directory containing this script
dir="$(dirname "$(realpath "$0")")"

# Set the device type
if [ -z "$TARGET_PRODUCT" ]; then
    # Make sure we have exactly one command-line argument (device type)
    [[ $# -eq 1 ]] || print_error "Expected a single argument (device type)"
    DEVICE=$1
else
    DEVICE=$(echo "$TARGET_PRODUCT" | cut -d '_' -f 2-)
fi

# Make sure the OUT environment variable set.
[[ -n $OUT ]] || print_error "Expected OUT in the environment"

# Get ROM root directory from OUT
ROM_ROOT="${OUT%\/out/*}"

# Extract the build ID from the build/make/core/build_id.mk file
build_id=$(grep -o 'BUILD_ID=.*' "$ROM_ROOT/build/make/core/build_id.mk" | cut -d "=" -f 2 | cut -c 1 | tr '[:upper:]' '[:lower:]')

# Make sure the BUILD_NUMBER environment variable set. Also build_id is not empty
[[ -n $BUILD_NUMBER ]] || print_error "Expected BUILD_NUMBER in the environment"
[[ -n $build_id ]] || print_error "Run this script in root dir also make sure cloned in [LINEAGEOS_ROOT]/script"

# Set the scheduling policy of this script to "batch" for better performance
chrt -b -p 0 $$

# Set the paths to the directories containing the keys
OLD_COMMON_KEY_DIR=$ROM_ROOT/keys/common
OLD_PERSISTENT_KEY_DIR=$ROM_ROOT/keys/$1
# Use common/device keys dir if it exists
if [ -d "$OLD_PERSISTENT_KEY_DIR" ]; then
    PERSISTENT_KEY_DIR=$OLD_PERSISTENT_KEY_DIR
elif [ -d "$OLD_COMMON_KEY_DIR" ]; then
    PERSISTENT_KEY_DIR=$OLD_COMMON_KEY_DIR
else
    COMMON_KEY_DIR=~/.android-certs
    PERSISTENT_KEY_DIR=~/.android-certs/$DEVICE
    # Use common keys if device dir doesnt exists
    if [ ! -d "$PERSISTENT_KEY_DIR" ]; then
        PERSISTENT_KEY_DIR=$COMMON_KEY_DIR
    fi
fi

# Decrypt the keys in advance for improved performance and modern algorithm support
# Copy the keys to a temporary directory and remove it when the script exits.
KEY_DIR="$OUT/keys"
if [ ! -d "$KEY_DIR" ]; then
    cp -r "$PERSISTENT_KEY_DIR" "$KEY_DIR"
    "$dir"/crypt_keys.sh -d "$KEY_DIR"
fi

# Set the target files name
TARGET_FILES=lineage_$DEVICE-target_files-$BUILD_NUMBER.zip

APEX_PACKAGE_LIST=$(cat "$dir/apex.list")

CONFIG_FILE="vendor/lineage/config/version.mk"
if [ ! -f "$CONFIG_FILE" ]; then
    # If version.mk doesn't exist, use common.mk
    CONFIG_FILE="vendor/lineage/config/common.mk"
fi

# Extract version information
PRODUCT_VERSION_MAJOR=$(grep -oP 'PRODUCT_VERSION_MAJOR = \K.*' "$CONFIG_FILE")
PRODUCT_VERSION_MINOR=$(grep -oP 'PRODUCT_VERSION_MINOR = \K.*' "$CONFIG_FILE")
LINEAGE_VER=$PRODUCT_VERSION_MAJOR.$PRODUCT_VERSION_MINOR

SIGN_TARGETS=()

if [[ "$build_id" == [rstu] ]]; then
    PACKAGE_LIST=(
        "OsuLogin"
        "ServiceWifiResources"
    )
    if [[ "$build_id" == [stu] ]]; then
        PACKAGE_LIST+=(
            "ServiceConnectivityResources"
        )
        if [[ "$build_id" == [tu] ]]; then
            PACKAGE_LIST+=(
                "AdServicesApk"
                "HalfSheetUX"
                "SafetyCenterResources"
                "ServiceUwbResources"
                "WifiDialog"
            )
        fi

        for PACKAGE in $APEX_PACKAGE_LIST; do
            if [ -f "$KEY_DIR/$PACKAGE.pem" ]; then
                SIGN_TARGETS+=(--extra_apks "$PACKAGE.apex=$KEY_DIR/$PACKAGE"
                    --extra_apex_payload_key "$PACKAGE.apex=$KEY_DIR/$PACKAGE.pem")
            elif [ -f "$KEY_DIR/avb.pem" ]; then
                SIGN_TARGETS+=(--extra_apks "$PACKAGE.apex=$KEY_DIR/releasekey"
                    --extra_apex_payload_key "$PACKAGE.apex=$KEY_DIR/avb.pem")
            else
                echo "APEX modules will signed using public payload key"
                SIGN_TARGETS+=(--extra_apks "$PACKAGE.apex=$KEY_DIR/releasekey"
                    --extra_apex_payload_key "$PACKAGE.apex=$ROM_ROOT/external/avb/test/data/testkey_rsa4096.pem")
            fi
        done
    fi

    for PACKAGE in "${PACKAGE_LIST[@]}"; do
        SIGN_TARGETS+=(--extra_apks "$PACKAGE.apk=$KEY_DIR/releasekey")
    done
fi

sign_target_files_apks -o -d "$KEY_DIR" "${SIGN_TARGETS[@]}" \
    "$OUT/obj/PACKAGING/target_files_intermediates/$TARGET_FILES" "$OUT/$TARGET_FILES"

ota_from_target_files -k "$KEY_DIR/releasekey" "$OUT/$TARGET_FILES" \
    "$OUT/lineage-$LINEAGE_VER-$BUILD_NUMBER-ota_package-$DEVICE-signed.zip" || exit 1

FASTBOOT_PACKAGE="lineage-$LINEAGE_VER-$BUILD_NUMBER-fastboot_package-$DEVICE.zip"
IMAGES=("recovery" "boot" "vendor_boot" "dtbo")

img_from_target_files "$OUT/$TARGET_FILES" "$OUT/$FASTBOOT_PACKAGE"

for i in "${!IMAGES[@]}"; do
    if unzip -l "$OUT/$FASTBOOT_PACKAGE" | grep -q "${IMAGES[i]}.img"; then
        unzip -o -j -q "$OUT/$FASTBOOT_PACKAGE" "${IMAGES[i]}.img" -d "$OUT"
        mv "$OUT/${IMAGES[i]}.img" "$OUT/lineage-$LINEAGE_VER-$BUILD_NUMBER-${IMAGES[i]}-$DEVICE.img"
    fi
done
