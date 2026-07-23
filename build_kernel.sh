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

# If non-root is selected, skip SUSFS & NoMount entirely
if [ "$BUILD_RESUKISU" != "y" ]; then
    BUILD_SUSFS=n
    BUILD_SUSFS_SPOOF_UNAME=n
    BUILD_NOMOUNT=n
else
    # Prompt for SUSFS if not set
    if [ -z "$BUILD_SUSFS" ]; then
        read -p "Build with SUSFS support? [y/N]: " susfs_choice
        case "$susfs_choice" in
            [yY][eE][sS]|[yY])
                BUILD_SUSFS=y
                ;;
            *)
                BUILD_SUSFS=n
                ;;
        esac
    fi

    # Prompt for Uname Spoofing if SUSFS is enabled
    if [ "$BUILD_SUSFS" = "y" ] && [ -z "$BUILD_SUSFS_SPOOF_UNAME" ]; then
        read -p "Enable SUSFS uname spoofing? [y/N]: " spoof_choice
        case "$spoof_choice" in
            [yY][eE][sS]|[yY])
                BUILD_SUSFS_SPOOF_UNAME=y
                ;;
            *)
                BUILD_SUSFS_SPOOF_UNAME=n
                ;;
        esac
    fi

    # Prompt for NoMount if not set
    if [ -z "$BUILD_NOMOUNT" ]; then
        read -p "Build with NoMount support? [y/N]: " nomount_choice
        case "$nomount_choice" in
            [yY][eE][sS]|[yY])
                BUILD_NOMOUNT=y
                ;;
            *)
                BUILD_NOMOUNT=n
                ;;
        esac
    fi
fi

# Prompt for DroidSpaces if not set
if [ -z "$BUILD_DROIDSPACES" ]; then
    read -p "Build with DroidSpaces support? [y/N]: " droidspaces_choice
    case "$droidspaces_choice" in
        [yY][eE][sS]|[yY])
            BUILD_DROIDSPACES=y
            ;;
        *)
            BUILD_DROIDSPACES=n
            ;;
    esac
fi

# Prompt for LTO mode if not set
if [ -z "$LTO" ]; then
    read -p "Select LTO mode [full/thin/none] (default: full): " lto_choice
    case "$lto_choice" in
        thin|THIN)
            LTO=thin
            ;;
        none|no|NONE|NO)
            LTO=none
            ;;
        *)
            LTO=full
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

# Configure LOCALVERSION string for all builds
unset LOCALVERSION

# Initial defconfig build
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" $KERNEL_DEFCONFIG || exit 1
sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-Capybara-Revived"/' "$OUT_DIR/.config"

if [ -n "$LTO" ]; then
    echo "Configuring LTO mode: ${LTO}..."
    sed -i '/CONFIG_LTO_/d' "$OUT_DIR/.config"
    case "$LTO" in
        full)
            echo "CONFIG_LTO_CLANG_FULL=y" >> "$OUT_DIR/.config"
            echo "CONFIG_LTO_CLANG=y" >> "$OUT_DIR/.config"
            ;;
        thin)
            echo "CONFIG_LTO_CLANG_THIN=y" >> "$OUT_DIR/.config"
            echo "CONFIG_LTO_CLANG=y" >> "$OUT_DIR/.config"
            ;;
        none|no)
            echo "CONFIG_LTO_NONE=y" >> "$OUT_DIR/.config"
            sed -i '/CONFIG_LTO_CLANG/d' "$OUT_DIR/.config"
            echo "CONFIG_LTO_CLANG=n" >> "$OUT_DIR/.config"
            ;;
    esac
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
fi


if [ -n "$TICKRATE" ]; then
    echo "Enabling custom tickrate: ${TICKRATE} Hz..."
    sed -i '/CONFIG_HZ_/d' "$OUT_DIR/.config"
    sed -i '/CONFIG_HZ=/d' "$OUT_DIR/.config"
    echo "CONFIG_HZ_${TICKRATE}=y" >> "$OUT_DIR/.config"
    echo "CONFIG_HZ=${TICKRATE}" >> "$OUT_DIR/.config"
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
fi

echo "Fetching and updating to the latest Baseband-guard security module..."
BBG_TMP="$KERNEL_DIR/out/baseband-guard"
if [ -d "$BBG_TMP/.git" ]; then
    (cd "$BBG_TMP" && (git pull origin main 2>/dev/null || git pull origin master 2>/dev/null)) || true
else
    mkdir -p "$OUT_DIR"
    git clone https://github.com/vc-teahouse/Baseband-guard.git --depth 1 "$BBG_TMP" || true
fi

if [ -d "$BBG_TMP" ]; then
    rsync -a --exclude='.git' --exclude='.github' "$BBG_TMP/" "$KERNEL_DIR/Baseband-guard/" 2>/dev/null || cp -r "$BBG_TMP/"* "$KERNEL_DIR/Baseband-guard/" 2>/dev/null || true
    rm -rf "$KERNEL_DIR/Baseband-guard/.github" 2>/dev/null || true
fi

echo "Enabling Baseband-guard in kernel configuration..."
echo "CONFIG_BBG=y" >> "$OUT_DIR/.config"

if [ "$BUILD_RESUKISU" = "y" ]; then
    echo "Fetching and updating to the latest ReSukiSU root manager..."
    git submodule update --init --remote --recursive KernelSU || git submodule update --init --recursive KernelSU
    (cd KernelSU && git checkout main 2>/dev/null && git pull origin main 2>/dev/null && git fetch --unshallow 2>/dev/null || true)

    echo "Enabling ReSukiSU in kernel configuration..."
    echo "CONFIG_KSU=y" >> "$OUT_DIR/.config"
    echo "CONFIG_KSU_TRACEPOINT_HOOK=y" >> "$OUT_DIR/.config"

    if [ "$BUILD_SUSFS" = "y" ]; then
        echo "Fetching latest SUSFS patches..."
        SUSFS_TMP="$KERNEL_DIR/out/susfs4ksu"
        if [ -d "$SUSFS_TMP/.git" ]; then
            (cd "$SUSFS_TMP" && git pull origin gki-android15-6.6) || true
        else
            mkdir -p "$OUT_DIR"
            git clone https://gitlab.com/simonpunk/susfs4ksu.git --branch gki-android15-6.6 --depth 1 "$SUSFS_TMP" || true
        fi
        if [ -d "$SUSFS_TMP/kernel_patches/fs" ]; then
            cp -u "$SUSFS_TMP/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/" 2>/dev/null || true
            cp -u "$SUSFS_TMP/kernel_patches/include/linux/susfs"* "$KERNEL_DIR/include/linux/" 2>/dev/null || true
        fi

        echo "Enabling SUSFS in kernel configuration..."
        echo "CONFIG_KSU_SUSFS=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS_SUS_MAP=y" >> "$OUT_DIR/.config"

        if [ "$BUILD_SUSFS_SPOOF_UNAME" = "y" ]; then
            echo "Enabling SUSFS uname spoofing..."
            echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$OUT_DIR/.config"
        else
            echo "Disabling SUSFS uname spoofing..."
            sed -i '/CONFIG_KSU_SUSFS_SPOOF_UNAME/d' "$OUT_DIR/.config"
            echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=n" >> "$OUT_DIR/.config"
        fi
    else
        echo "Disabling SUSFS in kernel configuration..."
        sed -i '/CONFIG_KSU_SUSFS/d' "$OUT_DIR/.config"
        echo "CONFIG_KSU_SUSFS=n" >> "$OUT_DIR/.config"
    fi

    if [ "$BUILD_NOMOUNT" = "y" ]; then
        echo "Fetching and updating to the latest NoMount source and patches..."
        NOMOUNT_TMP="$KERNEL_DIR/out/nomount"
        if [ -d "$NOMOUNT_TMP/.git" ]; then
            (cd "$NOMOUNT_TMP" && git pull origin master) || (cd "$NOMOUNT_TMP" && git pull origin main) || true
        else
            mkdir -p "$OUT_DIR"
            git clone https://github.com/maxsteeel/nomount.git --depth 1 "$NOMOUNT_TMP" || true
        fi

        if [ -d "$NOMOUNT_TMP/kernel/src" ]; then
            cp -u "$NOMOUNT_TMP/kernel/src/nomount.c" "$KERNEL_DIR/fs/" 2>/dev/null || true
            cp -u "$NOMOUNT_TMP/kernel/src/nomount.h" "$KERNEL_DIR/fs/" 2>/dev/null || true
        fi

        echo "Enabling NoMount in kernel configuration..."
        echo "CONFIG_NOMOUNT=y" >> "$OUT_DIR/.config"
    else
        echo "Disabling NoMount in kernel configuration..."
        sed -i '/CONFIG_NOMOUNT/d' "$OUT_DIR/.config"
        echo "CONFIG_NOMOUNT=n" >> "$OUT_DIR/.config"
    fi

    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
else
    echo "Disabling ReSukiSU, SUSFS & NoMount in kernel configuration..."
    sed -i '/CONFIG_KSU/d' "$OUT_DIR/.config"
    echo "CONFIG_KSU=n" >> "$OUT_DIR/.config"
    sed -i '/CONFIG_NOMOUNT/d' "$OUT_DIR/.config"
    echo "CONFIG_NOMOUNT=n" >> "$OUT_DIR/.config"
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
fi

if [ "$BUILD_DROIDSPACES" = "y" ]; then
    echo "Fetching and updating to the latest DroidSpaces patches..."
    DROIDSPACES_TMP="$KERNEL_DIR/out/droidspaces"
    if [ -d "$DROIDSPACES_TMP/.git" ]; then
        (cd "$DROIDSPACES_TMP" && (git pull origin main 2>/dev/null || git pull origin master 2>/dev/null)) || true
    else
        mkdir -p "$OUT_DIR"
        git clone https://github.com/ravindu644/Droidspaces-OSS.git --depth 1 "$DROIDSPACES_TMP" || true
    fi

    DROIDSPACES_PATCH="$DROIDSPACES_TMP/Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch"
    if [ -f "$DROIDSPACES_PATCH" ]; then
        echo "Applying DroidSpaces GKI patch..."
        patch -p1 --forward -r - < "$DROIDSPACES_PATCH" || true
    fi

    echo "Enabling DroidSpaces in kernel configuration..."
    echo "CONFIG_SYSVIPC=y" >> "$OUT_DIR/.config"
    echo "CONFIG_POSIX_MQUEUE=y" >> "$OUT_DIR/.config"
    echo "CONFIG_IPC_NS=y" >> "$OUT_DIR/.config"
    echo "CONFIG_PID_NS=y" >> "$OUT_DIR/.config"
    echo "CONFIG_DEVTMPFS=y" >> "$OUT_DIR/.config"
    echo "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y" >> "$OUT_DIR/.config"
    echo "CONFIG_USER_NS=y" >> "$OUT_DIR/.config"
    echo "CONFIG_NETFILTER_XT_TARGET_REJECT=y" >> "$OUT_DIR/.config"
    echo "CONFIG_NETFILTER_XT_TARGET_LOG=y" >> "$OUT_DIR/.config"
    echo "CONFIG_NETFILTER_XT_MATCH_RECENT=y" >> "$OUT_DIR/.config"
    echo "CONFIG_IP_SET=y" >> "$OUT_DIR/.config"
    echo "CONFIG_IP_SET_HASH_IP=y" >> "$OUT_DIR/.config"
    echo "CONFIG_IP_SET_HASH_NET=y" >> "$OUT_DIR/.config"
    echo "CONFIG_NETFILTER_XT_SET=y" >> "$OUT_DIR/.config"
    echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$OUT_DIR/.config"
    echo "CONFIG_TMPFS_XATTR=y" >> "$OUT_DIR/.config"

    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="-w" olddefconfig || exit 1
else
    echo "Disabling DroidSpaces in kernel configuration..."
    sed -i '/CONFIG_SYSVIPC/d' "$OUT_DIR/.config"
    echo "CONFIG_SYSVIPC=n" >> "$OUT_DIR/.config"
    sed -i '/CONFIG_POSIX_MQUEUE/d' "$OUT_DIR/.config"
    echo "CONFIG_POSIX_MQUEUE=n" >> "$OUT_DIR/.config"
    sed -i '/CONFIG_IPC_NS/d' "$OUT_DIR/.config"
    echo "CONFIG_IPC_NS=n" >> "$OUT_DIR/.config"
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
    if [ "$BUILD_SUSFS" = "y" ]; then
        ZIP_SUFFIX="${ZIP_SUFFIX}-susfs"
    fi
    if [ "$BUILD_NOMOUNT" = "y" ]; then
        ZIP_SUFFIX="${ZIP_SUFFIX}-nomount"
    fi
fi
if [ "$BUILD_DROIDSPACES" = "y" ]; then
    ZIP_SUFFIX="${ZIP_SUFFIX}-droidspace"
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
