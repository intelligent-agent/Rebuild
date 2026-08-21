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
TAG=$(git describe --always --tags)
NAME="rebuild-${VERSION}-${TAG}"

cd $BUILD_DIR
ARMBIAN_REF="v26.5.1" # sunxi-6.18 patches unchanged since being rewritten against v6.18.33 (see recore.csc)
git fetch --tags --prune
git reset --hard
git checkout "$ARMBIAN_REF"
rm -rf "userpatches"

cd "$ROOT_DIR"
cp -r "userpatches" "${BUILD_DIR}"
cp armbian/customize-image-"${VERSION}".sh "${BUILD_DIR}"/userpatches/customize-image.sh
cp armbian/recore.csc "${BUILD_DIR}"/config/boards
# NOTE: Armbian's patch/u-boot/u-boot-sunxi/allwinner-boot-splash.patch used to
# be deleted here (since 1c0c889, Jun 2023, "Patch is not overrwritten"). It is
# left in place now and adapted to instead - see
# userpatches/u-boot/u-boot-sunxi/u-boot-sunxi64-legacy-8-splash-preboot.patch.
# Patches are applied in alphabetical order by filename, so "allwinner-*" lands
# before "u-boot-sunxi64-legacy-*" and ours can build on top of it.

mkdir -p "${BUILD_DIR}"/userpatches/overlay/rebuild/
echo "${NAME}" >"${BUILD_DIR}"/userpatches/overlay/rebuild/rebuild-version
echo "${TAG}" >"${BUILD_DIR}"/userpatches/overlay/rebuild/rebuild-tag

cd "$BUILD_DIR"

# Drop Armbian's initrd cache before every build, or the image can ship an
# initramfs that has nothing to do with the rootfs beside it (#74).
#
# lib/functions/image/initrd.sh keys that cache on a manifest of hashes of the
# modules dir, /usr/bin/bash, /etc/initramfs, /etc/initramfs-tools,
# /usr/share/initramfs-tools and /etc/modprobe.d. Plymouth is in none of them,
# so changing the theme does not change the key - and on a hit it does
#
#     cp "${initrd_cache_file_path}" "${initrd_file}"
#
# straight over /boot/initrd.img-*, replacing whatever customize-image.sh built.
# Proven on rebuild-fluidd-22ae943: the shipped initrd was byte-identical
# (md5 830df592edcb2ad7c9258cedc5974b98) to a cached one carrying Theme=spinner,
# while the rootfs next to it correctly had Theme=recore and all 38 theme files.
# That is why the panel kept booting the stock spinner however often the theme
# was fixed.
#
# Costs one initramfs rebuild per image; it is seconds against a full build.
rm -f "${BUILD_DIR}"/cache/initrd/* 2>/dev/null || true

DOCKER_EXTRA_ARGS="--cpus=${cores}" ./compile.sh rebuild
IMG=$(ls -1 output/images/ | grep "img.xz$")

mv "$BUILD_DIR"/output/images/"$IMG" "${IMG_DIR}/${NAME}.img.xz"
echo "🍰 Finished building ${NAME}"
