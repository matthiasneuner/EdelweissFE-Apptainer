#!/bin/bash
# Builds the EdelweissFE image for one target cluster's CPU.
#
# Usage: scripts/build.sh --target=<leo5|leo4|vsc5|musica|generic> [--rebuild-base]
#
# Sources are the branch tips of the upstream repositories (EDELWEISSFE_REPO /
# EDELWEISSFE_BRANCH, MARMOT_REPO / MARMOT_BRANCH, defaults: the GitHub
# repositories, master), resolved to commits once and pinned for the
# build -- never whatever happens to be checked out locally. To build unpushed
# work, point *_REPO at a local clone and *_BRANCH at its branch.
#
# Access-controlled Marmot materials: MANUAL_MATERIALS="GCDP CDP" copies those
# directories from MANUAL_MATERIALS_DIR (default: ../Marmot/modules/materials
# next to this repository) into the build. Usually set in deploy.local.sh.
#
# The base layer (the pinned edelweissfe-dev conda environment) is built once
# per edelweissfe-dev version, read from the EdelweissFE commit being built,
# and cached in .build/. --rebuild-base forces a rebuild after editing
# edelweissfe-base.def.
#
# The image lands in .build/edelweissfe-<ef>-<marmot>[-<materials>]-<target>.sif;
# the name keys a cache, so the same commits are never built twice. Deploy it
# with scripts/deploy.sh. Never run two builds at once: they share
# .build/apptainer-cache.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_targets.sh"
parse_target "$@"
REBUILD_BASE=0
for arg in "$@"; do
    case "$arg" in
        --target=*) ;;
        --rebuild-base) REBUILD_BASE=1 ;;
        *) echo "usage: $0 --target=<$TARGETS> [--rebuild-base]" >&2; exit 1 ;;
    esac
done

MANUAL_MATERIALS="${MANUAL_MATERIALS:-}"
MANUAL_MATERIALS_DIR="${MANUAL_MATERIALS_DIR:-$APPTAINER_REPO_DIR/../Marmot/modules/materials}"
export APPTAINER_CACHEDIR="$BUILD_DIR/apptainer-cache"
mkdir -p "$BUILD_DIR"

EF_COMMIT=$(resolve_commit "$EDELWEISSFE_REPO" "$EDELWEISSFE_BRANCH")
MA_COMMIT=$(resolve_commit "$MARMOT_REPO" "$MARMOT_BRANCH")
echo "Target:      $TARGET ($ARCH_FLAGS)"
echo "EdelweissFE: $EDELWEISSFE_REPO $EDELWEISSFE_BRANCH @ ${EF_COMMIT:0:8}"
echo "Marmot:      $MARMOT_REPO $MARMOT_BRANCH @ ${MA_COMMIT:0:8}"
echo "Materials:   ${MANUAL_MATERIALS:-none}"

# The base image is keyed on the edelweissfe-dev version of the commit being
# built, so a version bump on the branch rebuilds it automatically.
DEV_VERSION=$(edelweissfe_dev_version "$EDELWEISSFE_REPO" "$EDELWEISSFE_BRANCH" "$EF_COMMIT")
[ -n "$DEV_VERSION" ] || { echo "ERROR: no conda/edelweissfe-dev/VERSION at $EDELWEISSFE_REPO @ $EF_COMMIT" >&2; exit 1; }
BASE_SIF="$BUILD_DIR/edelweissfe-base-$DEV_VERSION.sif"
if [ "$REBUILD_BASE" -eq 1 ] || [ ! -f "$BASE_SIF" ]; then
    echo "Building base layer (edelweissfe-dev=$DEV_VERSION) -> $BASE_SIF ..."
    apptainer build --fakeroot --force \
        --build-arg EDELWEISSFE_DEV_VERSION="$DEV_VERSION" \
        "$BASE_SIF" "$APPTAINER_REPO_DIR/edelweissfe-base.def"
else
    echo "Reusing base layer $BASE_SIF"
fi

# Local repositories are cloned inside the build: bind them to the mount points
# the .def creates in %setup, and clone from there.
BINDS=()
EF_CLONE="$EDELWEISSFE_REPO"
MA_CLONE="$MARMOT_REPO"
if [ -d "$EDELWEISSFE_REPO" ]; then
    BINDS+=(-B "$EDELWEISSFE_REPO:/opt/build-mounts/edelweissfe-repo:ro")
    EF_CLONE=/opt/build-mounts/edelweissfe-repo
fi
if [ -d "$MARMOT_REPO" ]; then
    BINDS+=(-B "$MARMOT_REPO:/opt/build-mounts/marmot-repo:ro")
    MA_CLONE=/opt/build-mounts/marmot-repo
fi
BUILD_ARGS=(
    --build-arg "BASE_IMAGE=$BASE_SIF"
    --build-arg "ARCH_FLAGS=$ARCH_FLAGS"
    --build-arg "EDELWEISSFE_REPO=$EF_CLONE"
    --build-arg "EDELWEISSFE_BRANCH=$EDELWEISSFE_BRANCH"
    --build-arg "EDELWEISSFE_COMMIT=$EF_COMMIT"
    --build-arg "MARMOT_REPO=$MA_CLONE"
    --build-arg "MARMOT_BRANCH=$MARMOT_BRANCH"
    --build-arg "MARMOT_COMMIT=$MA_COMMIT"
    --build-arg "MANUAL_MATERIALS=$MANUAL_MATERIALS"
)
MATERIALS_TAG=""
if [ -n "$MANUAL_MATERIALS" ]; then
    [ -d "$MANUAL_MATERIALS_DIR" ] || { echo "ERROR: MANUAL_MATERIALS_DIR=$MANUAL_MATERIALS_DIR does not exist" >&2; exit 1; }
    BINDS+=(-B "$MANUAL_MATERIALS_DIR:/opt/build-mounts/marmot-materials:ro")
    # The materials change the image without changing the two commits.
    MATERIALS_TAG="-$(echo "$MANUAL_MATERIALS" | tr 'A-Z ' 'a-z-' | tr -s '-')"
fi

SIF_PATH="$BUILD_DIR/edelweissfe-${EF_COMMIT:0:8}-${MA_COMMIT:0:8}${MATERIALS_TAG}${TARGET_TAG}.sif"
if [ -f "$SIF_PATH" ]; then
    echo "Reusing $SIF_PATH (same commits, materials and target; delete it to force a rebuild)"
else
    # mksquashfs -processors 1: its multi-threaded xz compression holds one
    # dictionary per thread and got OOM-killed on a small build host.
    apptainer build --fakeroot --mksquashfs-args "-processors 1" \
        "${BUILD_ARGS[@]}" "${BINDS[@]}" \
        "$SIF_PATH.part" "$APPTAINER_REPO_DIR/edelweissfe-debian-13.def"
    mv "$SIF_PATH.part" "$SIF_PATH"
fi

apptainer exec "$SIF_PATH" cat /opt/build_info.txt
apptainer exec "$SIF_PATH" grep -qx "Arch flags: $ARCH_FLAGS" /opt/build_info.txt \
    || { echo "FATAL: $SIF_PATH was not built with '$ARCH_FLAGS'" >&2; exit 1; }
echo "Built: $SIF_PATH"
