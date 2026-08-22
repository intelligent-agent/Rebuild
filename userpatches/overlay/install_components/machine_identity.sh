#!/bin/bash

# Ship no per-machine identity, so every board generates its own on first boot.
# Shared by all four variants - barebone duplicates post_build rather than
# sourcing it, and this is not something to have two copies of.
strip_machine_identity() {
    echo "🍰 strip machine identity"

    # Armbian's cached rootfs carries a set of SSH host keys, and every image
    # built on that cache inherits the same pair. Two boards flashed from
    # rebuild-barebone-891e72c both presented
    #
    #   SHA256:tADe3k31lQ/ApIZZe6lGD0A3bFrI/argPFJ5aeIlPQo (ED25519)
    #
    # with a key comment of root@0306b8450d0c - a build-container hostname - and
    # an mtime two weeks older than the image itself. Identical keys across every
    # board make host-key verification meaningless, and the images are published,
    # so the private halves are downloadable.
    #
    # machine-id has to go with them, and that is not a separate nicety. The
    # thing that regenerates missing host keys is sshd-keygen.service, gated on
    # ConditionFirstBoot=yes - which is false whenever /etc/machine-id is already
    # populated, as it was here, baked in at rootfs build time:
    #
    #   sshd-keygen.service ... skipped, unmet condition check ConditionFirstBoot=yes
    #
    # So deleting the keys alone would leave a board with no host keys and
    # nothing able to create them, and sshd would not start at all. Truncating
    # machine-id makes the next boot a first boot, which regenerates both. It
    # also stops every board sharing one machine-id, which feeds the systemd
    # journal ID and the DHCP DUID.
    #
    # Reflash's flash-cleanup deletes and regenerates host keys at flash time as
    # well; this is the other half, so an image flashed by any other route -
    # written straight to eMMC, say - cannot ship someone else's keys either.
    rm -f /etc/ssh/ssh_host_*

    # Truncate rather than delete: systemd treats an empty file as "uninitialised"
    # and fills it in, while a missing file on a read-only-ish early boot is the
    # case that leaves it unset.
    : > /etc/machine-id

    # Usually a symlink to /etc/machine-id, in which case it needs nothing. Only
    # a real file would carry a stale copy. Guarded with if rather than && so a
    # false test cannot trip set -e and fail the build.
    #
    # The truncate is explicitly non-fatal. This is a belt-and-braces step for a
    # file that is normally a symlink, and it must never be the reason an image
    # build dies - a read-only or unwritable path here cost a sandbox run exactly
    # that way. Still noisy on failure, so it cannot rot unnoticed.
    if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
        : > /var/lib/dbus/machine-id || echo "WARNING: could not truncate /var/lib/dbus/machine-id" >&2
    fi
}
