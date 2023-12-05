#!/bin/bash

set -e -x

VERSION=$1
cores=$2 # Allow define No cores

case $VERSION in
    barebone|mainsail|fluidd|octoprint|reflash)
        echo "🍰 Building $VERSION"
        ;;
    *)
        echo "Wrong argument '$1'"
        echo "Usage: $0 <barebone|mainsail|fluidd|octoprint|reflash>"
        exit 1
    ;;
esac

# Cores
reported_cores=$(nproc --all)
if [ ! -z $cores ] && [ $cores -gt $reported_cores ]; then
    echo "😿 Desired core count greater than reported available cores."
elif [ ! -z $cores ] && [ $cores -lt 1 ]; then
     echo "🙀 Desired core count cannot be less than 1"
fi

if [ -z "$cores" ] || [ $cores -gt $reported_cores ] || [ $cores -lt 1 ]; then
    echo "😻 Allowing docker to use all available cores ($reported_cores)"
    cores=$reported_cores # Set cores to reported number of cores
else
    echo "😺 Allowing docker to use $cores cores"
    cores=$reported_cores # Set cores to reported number of cores
fi

BUILD_DIR="../build-${VERSION}"
if ! test -d "$BUILD_DIR" ; then
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
git reset --hard
git pull
git checkout v23.08
rm -rf "userpatches"

cd "$ROOT_DIR"
cp -r "userpatches" "${BUILD_DIR}"
cp armbian/customize-image-"${VERSION}".sh "${BUILD_DIR}"/userpatches/customize-image.sh
cp -r armbian/install_components/ "${BUILD_DIR}"/userpatches/install_components/
cp armbian/recore.csc "${BUILD_DIR}"/config/boards
rm -f "${BUILD_DIR}/patch/u-boot/u-boot-sunxi/allwinner-boot-splash.patch"

cp armbian/watermark.png "${BUILD_DIR}"/packages/plymouth-theme-armbian/watermark.png

echo "${NAME}" > "${BUILD_DIR}"/userpatches/overlay/rebuild/rebuild-version

cd "$BUILD_DIR"
DOCKER_EXTRA_ARGS="--cpus=${cores}" ./compile.sh rebuild
IMG=$(ls -1 output/images/ | grep "img.xz$")

mv "$BUILD_DIR"/output/images/"$IMG" "${IMG_DIR}/${NAME}.img.xz"
echo "🍰 Finished building ${NAME}"
