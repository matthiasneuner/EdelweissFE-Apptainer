#!/bin/bash
# Compares the upstream branch tips against what edelweissfe-latest.sif on a
# cluster was built from, to tell whether build.sh + deploy.sh need to run.
#
# Usage: scripts/check_deployed.sh --target=<leo5|leo4|vsc5|musica>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_targets.sh"
parse_target "$@"
require_deploy_config

echo "=== Upstream ==="
echo "EdelweissFE commit: $(resolve_commit "$EDELWEISSFE_REPO" "$EDELWEISSFE_BRANCH") ($EDELWEISSFE_BRANCH)"
echo "Marmot commit: $(resolve_commit "$MARMOT_REPO" "$MARMOT_BRANCH") ($MARMOT_BRANCH)"
echo ""
echo "=== Deployed on $TARGET ($DEPLOY_DIR/edelweissfe-latest.sif) ==="
remote_container_exec "$DEPLOY_DIR/edelweissfe-latest.sif" cat /opt/build_info.txt \
    || echo "(nothing deployed yet, or unreadable)"
