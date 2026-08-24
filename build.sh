#!/bin/bash
#
# Compile script for Xiaomi 8450 kernel, dts and modules with AOSPA
# Copyright (C) 2024-2025 Adithya R.

SECONDS=0 # start builtin bash timer
KP_ROOT="$(realpath ../..)"
TC_DIR="$KP_ROOT/prebuilts-master/clang/host/linux-x86/clang-r510928"
PREBUILTS_DIR="$KP_ROOT/prebuilts/kernel-build-tools/linux-x86"
BRANCH="$(git branch --show-current)"
MODULES_REPO="sm8450-modules"
DT_REPO="sm8450-devicetrees"

DO_CLEAN=false
NO_LTO=false
ONLY_CONFIG=false
ONLY_KERNEL=false
ONLY_DTB=false
ONLY_MODULES=false
TARGET=
DTB_WILDCARD="*"
DTBO_WILDCARD="*"

while [ $# -gt 0 ]; do
    case "$1" in
        -c | --clean) DO_CLEAN=true ;;
        -n | --no-lto) NO_LTO=true ;;
        -o | --only-config) ONLY_CONFIG=true ;;
        -k | --only-kernel) ONLY_KERNEL=true ;;
        -d | --only-dtb) ONLY_DTB=true ;;
        -m | --only-modules) ONLY_MODULES=true ;;
        *) TARGET="$1" ;;
    esac
    shift
done

if [ -z "$TARGET" ]; then
    echo "Target (device) not specified!"
    exit 1
fi

if ! source .build.rc || [ -z "$SRC_ROOT" ]; then
    echo -e "Create a .build.rc file here and define\nSRC_ROOT=<path/to/aospa/source>"
    exit 1
fi

KERNEL_DIR="$SRC_ROOT/device/xiaomi/$TARGET-kernel"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "$KERNEL_DIR does not exist!"
    exit 1
fi

KERNEL_COPY_TO="$KERNEL_DIR"
DTB_COPY_TO="$KERNEL_DIR/dtbs"
DTBO_COPY_TO="$DTB_COPY_TO/dtbo.img"
VBOOT_DIR="$KERNEL_DIR/vendor_ramdisk"
VDLKM_DIR="$KERNEL_DIR/vendor_dlkm"

DEFCONFIG="gki_defconfig"
DEFCONFIGS="vendor/waipio_GKI.config \
vendor/xiaomi_GKI.config \
vendor/debugfs.config"

MODULES_SRC="../$MODULES_REPO/qcom/opensource"
MODULES="mmrm-driver \
audio-kernel \
camera-kernel \
cvp-kernel \
dataipa/drivers/platform/msm \
datarmnet/core \
datarmnet-ext/aps \
datarmnet-ext/offload \
datarmnet-ext/shs \
datarmnet-ext/perf \
datarmnet-ext/perf_tether \
datarmnet-ext/sch \
datarmnet-ext/wlan \
display-drivers/msm \
eva-kernel \
video-driver \
wlan/qcacld-3.0/.qca6490"

case "$TARGET" in
    "marble" )
        DTB_WILDCARD="ukee"
        DTBO_WILDCARD="marble-sm7475-pm8008-overlay"
        ;;
    "mondrian" )
        DTB_WILDCARD="cape"
        DTBO_WILDCARD="mondrian-sm8475-pm8008-overlay"
        ;;
    "cupid" )
        DTB_WILDCARD="waipio"
        DTBO_WILDCARD="cupid-sm8450-pm8008-overlay"
        ;;
esac

##
## Helper functions
##

echo_i() { echo -e "\n\033[1;36m==> $1\033[0m\n"; }

echo_w() { echo -e "\033[1;33m $1\033[0m"; }

echo_e() { echo -e "\n\033[1;31m $1\033[0m\n"; }

get_trees_rev() {
    kernel_rev="$(git rev-parse HEAD | cut -c1-10)"
    [[ -n "$(git --no-optional-locks status -uno --porcelain)" ]] && kernel_rev+="+"

    modules_rev="$(git -C ../$MODULES_REPO rev-parse HEAD | cut -c1-8)"
    [[ -n "$(git -C ../$MODULES_REPO --no-optional-locks status -uno --porcelain)" ]] && modules_rev+="+"

    dt_rev="$(git -C ../$DT_REPO rev-parse HEAD | cut -c1-8)"
    [[ -n "$(git -C ../$DT_REPO --no-optional-locks status -uno --porcelain)" ]] && dt_rev+="+"

    echo "-${kernel_rev}-m${modules_rev}-d${dt_rev}"
}

m() {
    make -j$(nproc --all) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
        DTC_EXT="$PREBUILTS_DIR/bin/dtc" \
        DTC_OVERLAY_TEST_EXT="$PREBUILTS_DIR/bin/ufdt_apply_overlay" \
        TARGET_PRODUCT=$TARGET $@ || exit $?
}

build_kernel() {
    echo_i "Building kernel image..."
    m Image
    cp out/arch/arm64/boot/Image $KERNEL_COPY_TO
    echo_i "Copied kernel to $KERNEL_COPY_TO."
}

build_modules() {
    echo_i "Building kernel modules..."
    m modules
    rm -rf out/modules out/*.ko
    m INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install

    echo_i "Building techpack modules..."
    for module in $MODULES; do
        echo -e "\nBuilding $module..."
        m -C $MODULES_SRC/$module M=$MODULES_SRC/$module KERNEL_SRC="$(pwd)" OUT_DIR="$(pwd)/out"
        m -C $MODULES_SRC/$module M=$MODULES_SRC/$module KERNEL_SRC="$(pwd)" OUT_DIR="$(pwd)/out" \
            INSTALL_MOD_PATH=modules INSTALL_MOD_STRIP=1 modules_install
    done

    first_stage_modules="$(cat modules.list.msm.waipio)"
    second_stage_modules="$(cat modules.list.second_stage modules.list.second_stage.$TARGET)"
    vendor_dlkm_modules="$(cat modules.list.vendor_dlkm modules.list.vendor_dlkm.$TARGET)"
    modules_out="out/modules/lib/modules/$(ls -t out/modules/lib/modules/ | head -n1)"

    rm -rf $VBOOT_DIR && mkdir -p $VBOOT_DIR
    rm -rf $VDLKM_DIR && mkdir -p $VDLKM_DIR

    echo_i "Copying first stage modules..."
    for module in $first_stage_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VBOOT_DIR
        echo $module >> $VBOOT_DIR/modules.load
        echo $module >> $VBOOT_DIR/modules.load.recovery
        echo $module
    done

    echo_i "Copying second stage modules..."
    for module in $second_stage_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VBOOT_DIR
        cp $mod_path $VDLKM_DIR
        echo $module >> $VBOOT_DIR/modules.load.recovery
        echo $module >> $VDLKM_DIR/modules.load
        echo $module
    done

    echo_i "Copying vendor_dlkm modules..."
    for module in $vendor_dlkm_modules; do
        mod_path=$(find $modules_out -name "$module" -print -quit)
        if [ -z "$mod_path" ]; then
            echo_w "Could not locate $module, skipping!"
            continue
        fi
        cp $mod_path $VDLKM_DIR
        echo $module >> $VDLKM_DIR/modules.load
        echo $module
    done

    for dest_dir in $VBOOT_DIR $VDLKM_DIR; do
        cp modules.vendor_blocklist.msm.waipio $dest_dir/modules.blocklist
        cp $modules_out/modules.{alias,dep,softdep} $dest_dir
    done

    sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]\|$)|/lib/modules/\2\3\4|g' $VBOOT_DIR/modules.dep
    sed -E -i 's|([^: ]*/)([^/]*\.ko)([:]?)([ ]\|$)|/vendor_dlkm/lib/modules/\2\3\4|g' $VDLKM_DIR/modules.dep
}

build_dtbs() {
    echo_i "Building dtbs..."
    m dtbs

    rm -rf out/dtbs{,-base}
    mkdir out/dtbs{,-base}
    mv  out/arch/arm64/boot/dts/vendor/qcom/$DTB_WILDCARD.dtb \
        out/arch/arm64/boot/dts/vendor/qcom/$DTBO_WILDCARD.dtbo \
        out/dtbs-base
    rm -f out/arch/arm64/boot/dts/vendor/qcom/*.dtbo
    ../../build/android/merge_dtbs.py out/dtbs-base out/arch/arm64/boot/dts/vendor/qcom/ out/dtbs || exit $?

    if [ -d "$DTB_COPY_TO" ]; then
        rm -f $DTB_COPY_TO/*.dtb
        cp out/dtbs/*.dtb $DTB_COPY_TO
    else
        rm -f $DTB_COPY_TO
        cat out/dtbs/*.dtb >> $DTB_COPY_TO
    fi
    echo_i "Copied dtb(s) to $DTB_COPY_TO."

    mkdtboimg.py create $DTBO_COPY_TO --page_size=4096 out/dtbs/*.dtbo
    echo_i "Generated dtbo.img to $DTBO_COPY_TO".
}

##
## Main logic starts here
##

export PATH="$TC_DIR/bin:$PREBUILTS_DIR/bin:$PATH"
export LOCALVERSION="$(get_trees_rev)"

$DO_CLEAN && {
    rm -rf out $MODULES_REPO
    echo_i "Cleaned output directories."
}

mkdir -p out

# A fresh clone has no KernelSU/ content, which leaves drivers/kernelsu
# dangling and makes drivers/Kconfig fail before a config can be generated.
# Only fetch when it is actually missing, so a checkout ahead of the recorded
# gitlink is never rolled back.
if [ ! -f KernelSU/kernel/Kconfig ]; then
    echo_i "Fetching KernelSU submodule..."
    git submodule update --init KernelSU || exit $?
fi

echo_i "Generating config..."
m $DEFCONFIG
m ./scripts/kconfig/merge_config.sh $DEFCONFIGS vendor/${TARGET}_GKI.config
scripts/config --file out/.config \
    --set-str LOCALVERSION "-$BRANCH" \
    -d LOCALVERSION_AUTO
$NO_LTO && {
    scripts/config --file out/.config \
        --set-str LOCALVERSION "-${BRANCH}-nolto" \
        -d LTO_CLANG_FULL -e LTO_NONE
    echo_i "Disabled LTO!"
}

# Guard against silently shipping a kernel with no root. A renamed or dropped
# symbol would otherwise just vanish during defconfig generation and produce a
# clean, working, root-less build with no indication anything went wrong.
for sym in CONFIG_KSU CONFIG_KSU_SUSFS; do
    grep -q "^${sym}=y" out/.config || {
        echo_e "$sym is not enabled in out/.config, refusing to build a kernel without KernelSU!"
        exit 1
    }
done
echo_i "KernelSU: $(git -C KernelSU describe --tags 2>/dev/null), SuSFS $(sed -n 's/^#define SUSFS_VERSION "\(.*\)"/\1/p' include/linux/susfs.h)"

$ONLY_CONFIG && exit

if $ONLY_KERNEL; then build_kernel
elif $ONLY_DTB; then build_dtbs
elif $ONLY_MODULES; then build_modules
else {
    build_kernel
    build_modules
    build_dtbs
}; fi


echo_i "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !"
