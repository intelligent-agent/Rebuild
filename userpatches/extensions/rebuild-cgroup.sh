#!/bin/bash
# Used only by Coron​​as CI.  Armbian calls this on the host immediately before
# launching its Docker build container, where DOCKER_EXTRA_ARGS is a real array.
# The shared slice has no CPU quota: one build consumes all cores, while two
# builds naturally share them.  Its MemoryHigh setting protects the host when
# both happen to be memory-heavy at once.
function host_pre_docker_launch__rebuild_cgroup() {
    [ -n "${REBUILD_CGROUP_PARENT:-}" ] || return 0
    DOCKER_EXTRA_ARGS+=("--cgroup-parent=${REBUILD_CGROUP_PARENT}")
}
