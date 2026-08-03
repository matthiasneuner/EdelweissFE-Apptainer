#!/bin/bash
# Rebuilds the EdelweissFE Apptainer image from a fixed target branch of
# EdelweissFE and Marmot (NOT whatever happens to be checked out locally --
# ambient working-tree state is incidental, not a deliberate choice) and
# deploys it to LEO5's central container location. See ../LEO5_RUNBOOK.md.
#
# Usage: scripts/rebuild_and_deploy_leo5.sh [--no-deploy] [--rebuild-base]
# Override the branches via EDELWEISSFE_BRANCH / MARMOT_BRANCH env vars.
#
# --rebuild-base forces a rebuild of the cached base layer (conda deps +
# Eigen/autodiff/Fastor) -- only needed after editing edelweissfe-base.def or
# EdelweissFE's conda_requirements.txt/pip_requirements.txt. Routine
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
EDELWEISSFE_BRANCH="${EDELWEISSFE_BRANCH:-feat/amr-recovery-marker}"
MARMOT_BRANCH="${MARMOT_BRANCH:-next_v26.11}"
MANUAL_MATERIALS="${MANUAL_MATERIALS:-}"
BUILD_DIR="$APPTAINER_REPO_DIR/.build"
LEO5_HOST="${LEO5_HOST:-c8441141@leo5.uibk.ac.at}"
LEO5_CONTAINER_DIR="${LEO5_CONTAINER_DIR:-/scratch/c8441141/containers}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek}"
DEPLOY=1
REBUILD_BASE=0
for arg in "$@"; do
    [ "$arg" = "--no-deploy" ] && DEPLOY=0
    [ "$arg" = "--rebuild-base" ] && REBUILD_BASE=1
done

mkdir -p "$BUILD_DIR"

BASE_SIF="$BUILD_DIR/edelweissfe-base.sif"
if [ "$REBUILD_BASE" -eq 1 ] || [ ! -f "$BASE_SIF" ]; then
    echo "Building base layer (conda deps + Eigen/autodiff/Fastor) -- this is the slow part," \
         "cached afterwards in $BASE_SIF ..."
    APPTAINER_CACHEDIR="$BUILD_DIR/apptainer-cache" apptainer build --fakeroot \
        "$BASE_SIF" "$APPTAINER_REPO_DIR/edelweissfe-base.def"
else
    echo "Reusing cached base layer: $BASE_SIF (pass --rebuild-base to force a rebuild," \
         "e.g. after editing edelweissfe-base.def or conda/pip requirements)"
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
    -e "s#git clone --recurse --branch [^ ]* https://github.com/MAteRialMOdelingToolbox/Marmot.git#git clone --recurse --branch $MA_BRANCH /media Marmot#" \
    -e "s#export MANUAL_MATERIALS=\"\"#export MANUAL_MATERIALS=\"$MANUAL_MATERIALS\"#" \
    "$DEF_TEMPLATE" > "$DEF_LOCAL"

# Materials affect image content independent of EF/MA SHA -- fold them into
# the cache key so a request with different MANUAL_MATERIALS can't silently
# reuse a build that lacks them.
MATERIALS_TAG=""
if [ -n "$MANUAL_MATERIALS" ]; then
    MATERIALS_TAG="-$(echo "$MANUAL_MATERIALS" | tr 'A-Z ' 'a-z-' | tr -s '-')"
fi
SHA_TAG="${EF_SHA}-${MA_SHA}${MATERIALS_TAG}"
SIF_NAME="edelweissfe-${SHA_TAG}.sif"
SIF_PATH="$BUILD_DIR/$SIF_NAME"

if [ -f "$SIF_PATH" ]; then
    echo "Reusing already-built $SIF_NAME (same EdelweissFE/Marmot commit pair -- delete it," \
         "or the whole .build/ dir, to force a rebuild)"
else
    echo "Building $SIF_NAME ..."
    APPTAINER_CACHEDIR="$BUILD_DIR/apptainer-cache" apptainer build --fakeroot \
        -B "$EDELWEISSFE_DIR:/mnt:ro" \
        -B "$MARMOT_DIR:/media:ro" \
        "$SIF_PATH" "$DEF_LOCAL"
    echo "Build OK: $SIF_PATH"
fi
apptainer exec "$SIF_PATH" cat /opt/build_info.txt

if [ "$DEPLOY" -eq 0 ]; then
    echo "--no-deploy given, stopping here. Local image: $SIF_PATH"
    exit 0
fi

echo "Deploying to $LEO5_HOST:$LEO5_CONTAINER_DIR/$SIF_NAME ..."
ssh -o BatchMode=yes "$LEO5_HOST" "mkdir -p $LEO5_CONTAINER_DIR"
scp -o BatchMode=yes "$SIF_PATH" "$LEO5_HOST:$LEO5_CONTAINER_DIR/$SIF_NAME"
ssh -o BatchMode=yes "$LEO5_HOST" "ln -sfn $LEO5_CONTAINER_DIR/$SIF_NAME $LEO5_CONTAINER_DIR/edelweissfe-latest.sif"

echo "Smoke-testing the deployed image on LEO5's login node ..."
ssh -o BatchMode=yes "$LEO5_HOST" \
    "module load $SINGULARITY_MODULE 2>/dev/null && singularity exec $LEO5_CONTAINER_DIR/edelweissfe-latest.sif edelweissfe --help >/dev/null && echo 'CLI OK'"

echo "Deployed. edelweissfe-latest.sif -> $SIF_NAME"
