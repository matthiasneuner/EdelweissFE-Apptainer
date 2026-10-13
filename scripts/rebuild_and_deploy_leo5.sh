#!/bin/bash
# Rebuilds the EdelweissFE Apptainer image from a fixed target branch of
# EdelweissFE and Marmot (NOT whatever happens to be checked out locally --
# ambient working-tree state is incidental, not a deliberate choice) and
# deploys it to LEO5's central container location. See ../LEO5_RUNBOOK.md.
#
# Usage: scripts/rebuild_and_deploy_leo5.sh [--no-deploy] [--rebuild-base] [--target=leo5|leo4|vsc5]
# Override the branches via EDELWEISSFE_BRANCH / MARMOT_BRANCH env vars.
#
# --target selects the deployment cluster, which fixes the CPU the compiled hot
# paths are built for (LEO5 = Ice Lake-SP w/ AVX-512; LEO4 = Broadwell
# E5-2690 v4, AVX2 only -- an Ice Lake image dies with SIGILL there; VSC-5 =
# AMD EPYC 7713 Zen3, AVX2 only, never build on VSC-5 itself), the
# deploy host and the Singularity module used for the smoke test. Non-LEO5
# images carry the target in their file name (edelweissfe-<shas>-leo4.sif), so
# the SHA-keyed build cache can never hand back an image for the wrong CPU.
#
# --rebuild-base forces a rebuild of the cached base layer (the pinned
# edelweissfe-dev conda environment) -- only needed after editing
# edelweissfe-base.def; a new edelweissfe-dev VERSION on the EdelweissFE branch
# gets a new base image automatically. Routine
# EdelweissFE/Marmot updates should NOT need this; the whole point of the
# base/top-layer split is to skip that slow part on every rebuild.
#
# MANUAL_MATERIALS="GCDP CDP" ./scripts/rebuild_and_deploy_leo5.sh -- include
# access-controlled, non-submodule Marmot materials that are already manually
# cloned into the local Marmot checkout's modules/materials/ (see
# LEO5_RUNBOOK.md). Empty by default.
set -euo pipefail

APPTAINER_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$APPTAINER_REPO_DIR/.." && pwd)"
EDELWEISSFE_DIR="${EDELWEISSFE_DIR:-$WORKSPACE_DIR/EdelweissFE}"
MARMOT_DIR="${MARMOT_DIR:-$WORKSPACE_DIR/Marmot}"
EDELWEISSFE_BRANCH="${EDELWEISSFE_BRANCH:-next_v26.11}"
MARMOT_BRANCH="${MARMOT_BRANCH:-next_v26.11}"
MANUAL_MATERIALS="${MANUAL_MATERIALS:-GCDP CDP}"
BUILD_DIR="$APPTAINER_REPO_DIR/.build"
LEO5_HOST="${LEO5_HOST:-c8441141@leo5.uibk.ac.at}"
LEO5_CONTAINER_DIR="${LEO5_CONTAINER_DIR:-/scratch/c8441141/containers}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek}"
CONTAINER_CMD=singularity
DEPLOY=1
REBUILD_BASE=0
TARGET=leo5
for arg in "$@"; do
    [ "$arg" = "--no-deploy" ] && DEPLOY=0
    [ "$arg" = "--rebuild-base" ] && REBUILD_BASE=1
    case "$arg" in --target=*) TARGET="${arg#--target=}" ;; esac
done
case "$TARGET" in
    leo5)
        ARCH_FLAGS="-march=icelake-server -mtune=icelake-server"
        TARGET_TAG=""
        ;;
    leo4)
        ARCH_FLAGS="-march=broadwell -mtune=broadwell"
        TARGET_TAG="-leo4"
        LEO5_HOST="${LEO4_HOST:-c8441141@leo4.uibk.ac.at}"
        LEO5_CONTAINER_DIR="${LEO4_CONTAINER_DIR:-/scratch/c8441141/containers}"
        SINGULARITY_MODULE="${LEO4_SINGULARITY_MODULE:-singularity/3.x}"
        ;;
    vsc5)
        # Key login is only a partial success on VSC-5 (an interactive second
        # factor follows): deploying needs the user's ControlMaster connection
        # (`ssh -fN vsc5`, see ~/.ssh/config host vsc5), so deploy from x9.
        ARCH_FLAGS="-march=znver3 -mtune=znver3"
        TARGET_TAG="-vsc5"
        LEO5_HOST="${VSC5_HOST:-vsc5}"
        LEO5_CONTAINER_DIR="${VSC5_CONTAINER_DIR:-/gpfs/data/fs73347/neuner/containers}"
        SINGULARITY_MODULE="${VSC5_APPTAINER_MODULE:-apptainer/1.1.9-gcc-12.2.0-ab3ze5o}"
        CONTAINER_CMD=apptainer
        ;;
    *) echo "ERROR: unknown --target=$TARGET (leo5|leo4|vsc5)" >&2; exit 1 ;;
esac
echo "Target: $TARGET (arch flags: $ARCH_FLAGS, deploy host: $LEO5_HOST)"

mkdir -p "$BUILD_DIR"

# The base layer is the pinned edelweissfe-dev conda environment; its version is
# taken from the EdelweissFE branch being built, and keys the cached base image,
# so a version bump on that branch rebuilds the base automatically.
DEV_VERSION=$(git -C "$EDELWEISSFE_DIR" show "$EDELWEISSFE_BRANCH:conda/edelweissfe-dev/VERSION" | tr -d '[:space:]')
BASE_SIF="$BUILD_DIR/edelweissfe-base-$DEV_VERSION.sif"
if [ "$REBUILD_BASE" -eq 1 ] || [ ! -f "$BASE_SIF" ]; then
    echo "Building base layer (edelweissfe-dev=$DEV_VERSION) -- this is the slow part," \
         "cached afterwards in $BASE_SIF ..."
    APPTAINER_CACHEDIR="$BUILD_DIR/apptainer-cache" apptainer build --fakeroot --force \
        --build-arg EDELWEISSFE_DEV_VERSION="$DEV_VERSION" \
        "$BASE_SIF" "$APPTAINER_REPO_DIR/edelweissfe-base.def"
else
    echo "Reusing cached base layer: $BASE_SIF (pass --rebuild-base to force a rebuild," \
         "e.g. after editing edelweissfe-base.def)"
fi

# Resolve the named branch's tip directly -- independent of whatever is
# currently checked out in the working tree.
EF_SHA=$(git -C "$EDELWEISSFE_DIR" rev-parse --short "$EDELWEISSFE_BRANCH")
MA_SHA=$(git -C "$MARMOT_DIR" rev-parse --short "$MARMOT_BRANCH")
EF_BRANCH="$EDELWEISSFE_BRANCH"
MA_BRANCH="$MARMOT_BRANCH"

echo "EdelweissFE: $EF_BRANCH @ $EF_SHA (currently checked out: $(git -C "$EDELWEISSFE_DIR" branch --show-current))"
echo "Marmot:      $MA_BRANCH @ $MA_SHA (currently checked out: $(git -C "$MARMOT_DIR" branch --show-current))"
echo "Manual materials: ${MANUAL_MATERIALS:-none}"

for pair in "EdelweissFE:$EDELWEISSFE_DIR:$EDELWEISSFE_BRANCH" "Marmot:$MARMOT_DIR:$MARMOT_BRANCH"; do
    name="${pair%%:*}"; rest="${pair#*:}"; dir="${rest%%:*}"; branch="${rest#*:}"
    if [ "$(git -C "$dir" branch --show-current)" = "$branch" ] && [ -n "$(git -C "$dir" status --short)" ]; then
        echo "WARNING: $name's $branch is checked out with uncommitted changes -- 'git clone' only" \
             "picks up committed history, so those changes will NOT be in the built image."
    fi
done

# git clone reads committed objects from the local repo (bind-mounted read-only
# below), not the working tree -- this is the same substitution used for local
# testing during the initial LEO5 port (see conversation/commit history).
DEF_TEMPLATE="$APPTAINER_REPO_DIR/edelweissfe-debian-13.def"
DEF_LOCAL="$BUILD_DIR/edelweissfe-debian-13.local.def"
sed \
    -e "s#^From: edelweissfe-base.sif#From: $BASE_SIF#" \
    -e "s#git clone --branch [^ ]* https://github.com/[^ ]*/EdelweissFE.git#git clone --branch $EF_BRANCH /mnt EdelweissFE#" \
    -e "s#git clone --recurse-submodules --branch [^ ]* https://github.com/MAteRialMOdelingToolbox/Marmot.git#git clone --recurse-submodules --branch $MA_BRANCH /media Marmot#" \
    -e "s#export MANUAL_MATERIALS=\"\"#export MANUAL_MATERIALS=\"$MANUAL_MATERIALS\"#" \
    -e "s#^    export ARCH_FLAGS=.*#    export ARCH_FLAGS=\"$ARCH_FLAGS\"#" \
    "$DEF_TEMPLATE" > "$DEF_LOCAL"

# Materials affect image content independent of EF/MA SHA -- fold them into
# the cache key so a request with different MANUAL_MATERIALS can't silently
# reuse a build that lacks them.
MATERIALS_TAG=""
if [ -n "$MANUAL_MATERIALS" ]; then
    MATERIALS_TAG="-$(echo "$MANUAL_MATERIALS" | tr 'A-Z ' 'a-z-' | tr -s '-')"
fi
SHA_TAG="${EF_SHA}-${MA_SHA}${MATERIALS_TAG}${TARGET_TAG}"
SIF_NAME="edelweissfe-${SHA_TAG}.sif"
SIF_PATH="$BUILD_DIR/$SIF_NAME"

if [ -f "$SIF_PATH" ]; then
    echo "Reusing already-built $SIF_NAME (same EdelweissFE/Marmot commit pair -- delete it," \
         "or the whole .build/ dir, to force a rebuild)"
else
    echo "Building $SIF_NAME ..."
    # -processors 1: mksquashfs's default multi-threaded xz compression got
    # OOM-killed packaging the final SIF on this memory-constrained build
    # host (each thread holds its own compression dictionary) -- single
    # process is slower but fits in the memory actually available.
    APPTAINER_CACHEDIR="$BUILD_DIR/apptainer-cache" apptainer build --fakeroot \
        --mksquashfs-args "-processors 1" \
        -B "$EDELWEISSFE_DIR:/mnt:ro" \
        -B "$MARMOT_DIR:/media:ro" \
        "$SIF_PATH" "$DEF_LOCAL"
    echo "Build OK: $SIF_PATH"
fi
apptainer exec "$SIF_PATH" cat /opt/build_info.txt
apptainer exec "$SIF_PATH" grep -qx "Arch flags: $ARCH_FLAGS" /opt/build_info.txt \
    || { echo "FATAL: $SIF_NAME was not built with '$ARCH_FLAGS'" >&2; exit 1; }

if [ "$DEPLOY" -eq 0 ]; then
    echo "--no-deploy given, stopping here. Local image: $SIF_PATH"
    exit 0
fi

echo "Deploying to $LEO5_HOST:$LEO5_CONTAINER_DIR/$SIF_NAME ..."
ssh -o BatchMode=yes "$LEO5_HOST" "mkdir -p $LEO5_CONTAINER_DIR"
scp -o BatchMode=yes "$SIF_PATH" "$LEO5_HOST:$LEO5_CONTAINER_DIR/$SIF_NAME"
ssh -o BatchMode=yes "$LEO5_HOST" "ln -sfn $LEO5_CONTAINER_DIR/$SIF_NAME $LEO5_CONTAINER_DIR/edelweissfe-latest.sif"

# `bash -c` + sourcing the module init explicitly: LEO4's login shell prints a
# long banner, and its non-interactive ssh shell has no `module` function.
echo "Smoke-testing the deployed image on $TARGET's login node ..."
ssh -q -o BatchMode=yes "$LEO5_HOST" \
    "source /etc/profile.d/modules.sh 2>/dev/null; module load $SINGULARITY_MODULE 2>/dev/null && $CONTAINER_CMD exec $LEO5_CONTAINER_DIR/edelweissfe-latest.sif edelweissfe --help >/dev/null && echo 'CLI OK'"

echo "Deployed. edelweissfe-latest.sif -> $SIF_NAME"
