#!/bin/bash

set -e -x

VERSION=$1
cores=$2 # Allow define No cores

case $VERSION in
barebone | mainsail | fluidd | octoprint)
    echo "🍰 Building $VERSION"
    ;;
*)
    echo "Wrong argument '$1'"
    echo "Usage: $0 <barebone|mainsail|fluidd|octoprint> [cores]"
    echo "  cores  number of CPU cores to give the build container."
    echo "         Defaults to all available ($(nproc))."
    exit 1
    ;;
esac

# Cores
reported_cores=$(nproc)
if [ ! -z $cores ] && [ $cores -gt $reported_cores ]; then
    echo "😿 Desired core count greater than reported available cores."
elif [ ! -z $cores ] && [ $cores -lt 1 ]; then
    echo "🙀 Desired core count cannot be less than 1"
fi

if [ -z "$cores" ] || [ $cores -gt $reported_cores ] || [ $cores -lt 1 ]; then
    echo "😻 Allowing docker to use all available cores ($reported_cores)"
    cores=$reported_cores
else
    echo "😺 Allowing docker to use $cores cores"
fi

BUILD_DIR="../build-${VERSION}"
if ! test -d "$BUILD_DIR"; then
    echo "$BUILD_DIR missing"
    git clone https://github.com/armbian/build $BUILD_DIR
fi

IMG_DIR="../images"
if [[ ! -e $IMG_DIR ]]; then
    echo "Creating Output directory $IMG_DIR"
    mkdir $IMG_DIR
elif [[ ! -d $IMG_DIR ]]; then
    echo "$IMG_DIR exists but not a directory"
    exit 20 # Not a directory
fi

ROOT_DIR=$(pwd)
# Overridable because `git describe` answers differently depending on how the
# tree was cloned, not on what is being built: a shallow clone has no tags, so
# --tags matches nothing and the --always fallback emits a bare hash. The
# workflow now fetches tags, so the default resolves; this stays so a caller can
# pin the name explicitly rather than depend on clone depth.
TAG=${REBUILD_VERSION:-$(git describe --always --tags)}
NAME="rebuild-${VERSION}-${TAG}"

cd $BUILD_DIR
# The commit Armbian's trunk.84 Recore images were built from: it carries
# everything Rebuild used to copy in - the Recore device trees (#10850), the
# U-Boot board patches and BL31 in DRAM (#10853), and the A5/A6 GPU clock,
# thermal trips and crash log (#10940) - byte for byte, so none of it is
# copied any more (#117).
ARMBIAN_REF="813ae7cf3ccd40df1d287733e1838ed0812ceeb8"
git fetch --tags --prune
git reset --hard
git checkout "$ARMBIAN_REF"
# `git reset --hard` restores the files Armbian tracks but keeps any it does
# not, and earlier builds in this tree copied patches into patch/: clean them
# out so they cannot be applied on top of Armbian's own.
git clean -fdq -- patch/
rm -rf "userpatches"

cd "$ROOT_DIR"
cp -r "userpatches" "${BUILD_DIR}"
cp armbian/customize-image-"${VERSION}".sh "${BUILD_DIR}"/userpatches/customize-image.sh
# NOTE: Armbian's patch/u-boot/u-boot-sunxi/allwinner-boot-splash.patch used to
# be deleted here (since 1c0c889, Jun 2023, "Patch is not overrwritten"). It is
# left in place now and adapted to instead - see
# userpatches/u-boot/u-boot-sunxi/u-boot-sunxi64-legacy-8-splash-preboot.patch.
# Patches are applied in alphabetical order by filename, so "allwinner-*" lands
# before "u-boot-sunxi64-legacy-*" and ours can build on top of it.

# Version Armbian's packages after this build, not just Armbian's own VERSION:
# every build labelled its kernel, device trees and U-Boot 26.11.0-trunk
# whatever they contained, so apt could not tell two builds apart, and the
# pins in rebuild-armbian-tested (#114) name exact versions. A `+` suffix keeps
# them sorting above Armbian's own 26.11.0-trunk. Debian versions allow no
# hyphen after the first one, hence the dots.
echo "$(cat "${BUILD_DIR}"/VERSION)+rebuild.$(echo "${TAG#v}" | tr -- '-' '.')" \
    >"${BUILD_DIR}"/userpatches/VERSION

mkdir -p "${BUILD_DIR}"/userpatches/overlay/rebuild/
echo "${NAME}" >"${BUILD_DIR}"/userpatches/overlay/rebuild/rebuild-version
echo "${TAG}" >"${BUILD_DIR}"/userpatches/overlay/rebuild/rebuild-tag

# Rebuild's own files, as the packages customize-image.sh installs.
packaging/build-debs "${BUILD_DIR}"/userpatches/overlay/debs "${TAG}"

cd "$BUILD_DIR"

# If you change the Plymouth theme (or anything else the initramfs carries but
# Armbian does not hash), clear its initrd cache by hand first:
#
#     rm -f "${BUILD_DIR}"/cache/initrd/*
#
# lib/functions/image/initrd.sh keys that cache on a manifest of the modules
# dir, /usr/bin/bash, /etc/initramfs, /etc/initramfs-tools,
# /usr/share/initramfs-tools and /etc/modprobe.d. Nothing under /etc/plymouth or
# /usr/share/plymouth is in it, so a theme change does not change the key - and
# on a hit it does `cp "${initrd_cache_file_path}" "${initrd_file}"` straight
# over /boot/initrd.img-*, discarding whatever customize-image.sh built.
# Proven on rebuild-fluidd-22ae943: the shipped initrd was byte-identical
# (md5 830df592edcb2ad7c9258cedc5974b98) to a cached one carrying Theme=spinner,
# while the rootfs beside it correctly had Theme=recore and all 38 theme files
# (#74). Left manual on purpose - it costs an initramfs rebuild every image.
# The cgroup parent is added by the optional rebuild-cgroup Armbian extension.
# DOCKER_EXTRA_ARGS arrives from the environment as one scalar array member,
# so it must contain exactly one Docker argument here.
DOCKER_EXTRA_ARGS="--cpus=${cores}" ./compile.sh rebuild
IMG=$(ls -1 output/images/ | grep "img.xz$")

mv "$BUILD_DIR"/output/images/"$IMG" "${IMG_DIR}/${NAME}.img.xz"
echo "🍰 Finished building ${NAME}"
