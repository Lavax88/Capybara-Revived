#!/bin/bash
set -e

# Configuration
DIR=$(readlink -f .)
MAIN=$(readlink -f ${DIR}/..)
KERNEL_DEFCONFIG=capybara_revived_defconfig
CLANG_DIR="$MAIN/toolchains/clang"
KERNEL_DIR=$(pwd)
OUT_DIR="$KERNEL_DIR/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DTB_DTBO_DIR="$ZIMAGE_DIR/dts/vendor/qcom"
BUILD_START=$(date +"%s")

# Prompt for ReSukiSU if not already set in environment
if [ -z "$BUILD_RESUKISU" ]; then
    read -p "Build with ReSukiSU support? [y/N]: " ksu_choice
    case "$ksu_choice" in
        [yY][eE][sS]|[yY])
            BUILD_RESUKISU=y
            ;;
        *)
            BUILD_RESUKISU=n
            ;;
    esac
fi

# Function to check for existing Clang
check_clang() {
    if [ -d "$CLANG_DIR" ] && [ -f "$CLANG_DIR/bin/clang" ]; then
        export PATH="$CLANG_DIR/bin:$PATH"
        export KBUILD_COMPILER_STRING="$($CLANG_DIR/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"
        echo "Found existing Clang: $KBUILD_COMPILER_STRING"
        return 0
    fi
    return 1
}

# Install Clang if needed
if ! check_clang; then
    echo "No valid Clang found. Installing Neutron Clang via antman..."
    mkdir -p "$CLANG_DIR"
    wget -q "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" -O "$CLANG_DIR/antman" || exit 1
    chmod +x "$CLANG_DIR/antman"
    (cd "$CLANG_DIR" && ./antman -S=latest --noconfirm) || exit 1

    if ! check_clang; then
        echo "Clang installation failed. Exiting..."
        exit 1
    fi
fi

# Set up toolchain
export ARCH=arm64
export SUBARCH=arm64

# Build kernel
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" $KERNEL_DEFCONFIG || exit 1

if [ -n "$TICKRATE" ]; then
    echo "Enabling custom tickrate: ${TICKRATE} Hz..."
    sed -i '/CONFIG_HZ_/d' "$OUT_DIR/.config"
    sed -i '/CONFIG_HZ=/d' "$OUT_DIR/.config"
    echo "CONFIG_HZ_${TICKRATE}=y" >> "$OUT_DIR/.config"
    echo "CONFIG_HZ=${TICKRATE}" >> "$OUT_DIR/.config"
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
fi

if [ "$BUILD_RESUKISU" = "y" ]; then
    echo "Ensuring ReSukiSU submodule is initialized..."
    git submodule update --init --recursive || exit 1
    
    echo "Enabling ReSukiSU in kernel configuration..."
    echo "CONFIG_KSU=y" >> "$OUT_DIR/.config"
    echo "CONFIG_KSU_TRACEPOINT_HOOK=y" >> "$OUT_DIR/.config"
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
fi

make -j17 O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" || exit 1

# Clean up old kernel zip files
echo "Cleaning up old kernel zip files..."
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Capybara-Revived-*.zip" -exec rm -v {} \;

# Create temporary anykernel directory
TIME=$(date "+%Y%m%d-%H%M%S")
TEMP_ANY_KERNEL_DIR="$KERNEL_DIR/anykernel_temp"
rm -rf "$TEMP_ANY_KERNEL_DIR"

# Clone entire anykernel directory
echo "Cloning anykernel directory..."
if [ -d "$KERNEL_DIR/anykernel" ]; then
    cp -r "$KERNEL_DIR/anykernel" "$TEMP_ANY_KERNEL_DIR"
else
    echo "Error: anykernel directory not found!"
    exit 1
fi

# Copy kernel image
if [ -f "$ZIMAGE_DIR/Image.gz-dtb" ]; then
    cp -v "$ZIMAGE_DIR/Image.gz-dtb" "$TEMP_ANY_KERNEL_DIR/"
elif [ -f "$ZIMAGE_DIR/Image.gz" ]; then
    cp -v "$ZIMAGE_DIR/Image.gz" "$TEMP_ANY_KERNEL_DIR/"
elif [ -f "$ZIMAGE_DIR/Image" ]; then
    cp -v "$ZIMAGE_DIR/Image" "$TEMP_ANY_KERNEL_DIR/"
fi

# Create zip file in kernel root directory
echo "Creating zip package..."
ZIP_SUFFIX=""
if [ "$BUILD_RESUKISU" = "y" ]; then
    ZIP_SUFFIX="-ReSukiSU"
fi
ZIP_NAME="Capybara-Revived${ZIP_SUFFIX}-$TIME.zip"
cd "$TEMP_ANY_KERNEL_DIR"
zip -r9 "$KERNEL_DIR/$ZIP_NAME" ./*
cd ..

# Clean up temporary directory
rm -rf "$TEMP_ANY_KERNEL_DIR"

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Final zip: $KERNEL_DIR/$ZIP_NAME"
echo "Zip size: $(du -h "$KERNEL_DIR/$ZIP_NAME" | cut -f1)"
echo "=========================================="
