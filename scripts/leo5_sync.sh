#!/bin/bash
# Syncs a workspace-root project directory (e.g. Pryout_anchorwashernut,
# containing .inp files, mesh/, incfiles/, and results) with its mirror under
# $SCRATCH on LEO5.
#
# Usage:
#   scripts/leo5_sync.sh push <project-dir-name> [extra rsync args...]
#   scripts/leo5_sync.sh pull <project-dir-name> [extra rsync args...]
set -euo pipefail

ACTION="${1:?usage: leo5_sync.sh push|pull <project-dir-name> [extra rsync args...]}"
PROJECT="${2:?usage: leo5_sync.sh push|pull <project-dir-name> [extra rsync args...]}"
shift 2

APPTAINER_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$(cd "$APPTAINER_REPO_DIR/.." && pwd)"
LOCAL_DIR="$WORKSPACE_DIR/$PROJECT"
LEO5_HOST="${LEO5_HOST:-c8441141@leo5.uibk.ac.at}"
REMOTE_DIR="${LEO5_SCRATCH:-/scratch/c8441141}/$PROJECT"

case "$ACTION" in
    push)
        [ -d "$LOCAL_DIR" ] || { echo "No such local project directory: $LOCAL_DIR" >&2; exit 1; }
        ssh -o BatchMode=yes "$LEO5_HOST" "mkdir -p '$REMOTE_DIR'"
        rsync -avz --progress -e "ssh -o BatchMode=yes" "$@" "$LOCAL_DIR/" "$LEO5_HOST:$REMOTE_DIR/"
        ;;
    pull)
        mkdir -p "$LOCAL_DIR"
        rsync -avz --progress -e "ssh -o BatchMode=yes" "$@" "$LEO5_HOST:$REMOTE_DIR/" "$LOCAL_DIR/"
        ;;
    *)
        echo "Usage: $0 push|pull <project-dir-name> [extra rsync args...]" >&2
        exit 1
        ;;
esac
