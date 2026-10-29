#!/bin/bash
# Copies a built image to a cluster, points edelweissfe-latest.sif at it and
# smoke-tests it on the login node.
#
# Usage: scripts/deploy.sh --target=<leo5|leo4|vsc5|musica> [--via-host=<ssh-host>] <path/to/image.sif>
#
# --via-host: the image lives on another machine (e.g. the build host) at that
# path; it is streamed from there through this machine. Use it when the build
# host cannot log in to the cluster itself (VSC-5: key login is followed by an
# interactive second factor, so only a machine holding an open ControlMaster
# connection can deploy).
#
# The destination comes from <TARGET>_HOST and <TARGET>_CONTAINER_DIR (see
# deploy.local.sh.example). The copy is verified by checksum before the
# symlink moves.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_targets.sh"
parse_target "$@"
require_deploy_config
VIA_HOST=""
SIF=""
for arg in "$@"; do
    case "$arg" in
        --target=*) ;;
        --via-host=*) VIA_HOST="${arg#--via-host=}" ;;
        *) SIF="$arg" ;;
    esac
done
[ -n "$SIF" ] || { echo "usage: $0 --target=<name> [--via-host=<host>] <image.sif>" >&2; exit 1; }
NAME="$(basename "$SIF")"
case "$NAME" in
    *"$TARGET_TAG.sif") ;;
    *) echo "ERROR: $NAME was not built for target '$TARGET' (expected *$TARGET_TAG.sif)" >&2; exit 1 ;;
esac

on_source() { if [ -n "$VIA_HOST" ]; then ssh -o BatchMode=yes "$VIA_HOST" "$@"; else bash -c "$*"; fi; }
DEST="$DEPLOY_DIR/$NAME"

echo "Deploying $NAME to $DEPLOY_HOST:$DEPLOY_DIR ..."
ssh -o BatchMode=yes "$DEPLOY_HOST" "mkdir -p '$DEPLOY_DIR'"
on_source "cat '$SIF'" | ssh -o BatchMode=yes "$DEPLOY_HOST" "cat > '$DEST.part'"
SRC_SUM=$(on_source "sha256sum '$SIF'" | cut -d' ' -f1)
DST_SUM=$(ssh -o BatchMode=yes "$DEPLOY_HOST" "sha256sum '$DEST.part'" | cut -d' ' -f1)
[ "$SRC_SUM" = "$DST_SUM" ] || { echo "FATAL: checksum mismatch ($SRC_SUM vs $DST_SUM)" >&2; exit 1; }
ssh -o BatchMode=yes "$DEPLOY_HOST" \
    "mv '$DEST.part' '$DEST' && ln -sfn '$DEST' '$DEPLOY_DIR/edelweissfe-latest.sif'"
echo "Copied, sha256 $SRC_SUM"

echo "Smoke-testing on $TARGET's login node ..."
LATEST="$DEPLOY_DIR/edelweissfe-latest.sif"
remote_container_exec "$LATEST" edelweissfe --help >/dev/null
# ssh forwards stdin, so the test program travels without remote quoting.
remote_container_exec "$LATEST" env PYTHON_GIL=0 OMP_NUM_THREADS=1 python - \
    < "$APPTAINER_REPO_DIR/scripts/smoke_test.py"
remote_container_exec "$LATEST" cat /opt/build_info.txt
echo "Deployed: edelweissfe-latest.sif -> $NAME (CLI, Marmot/AMGCL/Pardiso imports and free threading OK)"
