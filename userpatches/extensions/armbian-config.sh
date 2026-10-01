# Replaces Armbian's armbian-config extension, which Armbian main enables for
# every build (lib/functions/configuration/main-config.sh) and which would
# install armbian-config - after customize-image, out of reach of
# post_build's purge - and add github.armbian.com/configng as an apt source.
#
# enable_extension looks in userpatches/extensions before Armbian's own, so
# this file is what gets loaded, and it defines no hooks: nothing is installed
# and no source is added. Rebuild does not support what armbian-config is for,
# changing the kernel or bootloader by hand, past the pins in
# rebuild-armbian-tested (#114).
