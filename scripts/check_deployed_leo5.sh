#!/bin/bash
# Compares the current local EdelweissFE/Marmot checkouts against whatever is
# baked into edelweissfe-latest.sif on LEO5, so you know whether
# rebuild_and_deploy_leo5.sh needs to run before submitting new jobs.
set -euo pipefail

APPTAINER_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$APPTAINER_REPO_DIR/.." && pwd)"
EDELWEISSFE_DIR="${EDELWEISSFE_DIR:-$WORKSPACE_DIR/EdelweissFE}"
MARMOT_DIR="${MARMOT_DIR:-$WORKSPACE_DIR/Marmot}"
LEO5_HOST="${LEO5_HOST:-c8441141@leo5.uibk.ac.at}"
LEO5_CONTAINER_DIR="${LEO5_CONTAINER_DIR:-/scratch/c8441141/containers}"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek}"

echo "=== Local checkouts ==="
echo "EdelweissFE: $(git -C "$EDELWEISSFE_DIR" branch --show-current) @ $(git -C "$EDELWEISSFE_DIR" rev-parse --short HEAD)"
echo "Marmot:      $(git -C "$MARMOT_DIR" branch --show-current) @ $(git -C "$MARMOT_DIR" rev-parse --short HEAD)"

echo ""
echo "=== Deployed on LEO5 ($LEO5_CONTAINER_DIR/edelweissfe-latest.sif) ==="
ssh -o BatchMode=yes "$LEO5_HOST" \
    "module load $SINGULARITY_MODULE 2>/dev/null && singularity exec $LEO5_CONTAINER_DIR/edelweissfe-latest.sif cat /opt/build_info.txt" \
    2>/dev/null || echo "(nothing deployed yet, or it's unreadable -- run rebuild_and_deploy_leo5.sh)"
