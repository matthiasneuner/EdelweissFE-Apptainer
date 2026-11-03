# Shared by build.sh, deploy.sh and check_deployed.sh: the per-cluster
# settings, selected by --target=<name>. Source this file, then call
# load_target <name>.
#
# Public cluster facts (CPU, Apptainer module) and the upstream sources live
# here. Who deploys where (login, container directory) is personal and lives
# in deploy.local.sh at the repository root (git-ignored; copy
# deploy.local.sh.example), or in the environment: <TARGET>_HOST,
# <TARGET>_CONTAINER_DIR, MANUAL_MATERIALS, MANUAL_MATERIALS_DIR. The
# environment wins over deploy.local.sh.

APPTAINER_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$APPTAINER_REPO_DIR/.build}"
TARGETS="leo5 leo4 vsc5 musica generic"

# Sets for target $1:
#   TARGET, ARCH_FLAGS, TARGET_TAG (image-name suffix), CONTAINER_MODULE,
#   CONTAINER_CMD, DEPLOY_HOST, DEPLOY_DIR (empty if not configured).
load_target() {
    TARGET="$1"
    TARGET_TAG="-$TARGET"
    case "$TARGET" in
        # LEO5 (Uni Innsbruck): Intel Xeon Platinum 8358 (Ice Lake-SP), AVX-512.
        leo5)
            ARCH_FLAGS="-march=icelake-server -mtune=icelake-server"
            CONTAINER_MODULE="singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek"
            CONTAINER_CMD=singularity
            ;;
        # LEO4 (Uni Innsbruck): Intel Xeon E5-2690 v4 (Broadwell), AVX2 only --
        # an Ice Lake image dies with SIGILL there.
        leo4)
            ARCH_FLAGS="-march=broadwell -mtune=broadwell"
            CONTAINER_MODULE="singularity/3.x"
            CONTAINER_CMD=singularity
            ;;
        # VSC-5 (Vienna): AMD EPYC 7713 (Zen 3), AVX2, no AVX-512.
        vsc5)
            ARCH_FLAGS="-march=znver3 -mtune=znver3"
            CONTAINER_MODULE="apptainer/1.1.9-gcc-12.2.0-ab3ze5o"
            CONTAINER_CMD=apptainer
            ;;
        # MUSICA (ASC, Vienna and Innsbruck sites): AMD EPYC 9654 (Zen 4), AVX2 and AVX-512.
        # Apptainer is part of the nodes' system installation (no module needed).
        musica)
            ARCH_FLAGS="-march=znver4 -mtune=znver4"
            CONTAINER_MODULE=""
            CONTAINER_CMD=apptainer
            ;;
        # Any x86 CPU with AVX2/FMA; same flags as the CI release image.
        generic)
            ARCH_FLAGS="-march=x86-64-v3"
            CONTAINER_MODULE=""
            CONTAINER_CMD=apptainer
            ;;
        *)
            echo "ERROR: unknown target '$TARGET' (one of: $TARGETS)" >&2
            exit 1
            ;;
    esac

    local config="${DEPLOY_CONFIG:-$APPTAINER_REPO_DIR/deploy.local.sh}"
    # shellcheck source=/dev/null
    [ -f "$config" ] && source "$config"
    local host_var="${TARGET^^}_HOST" dir_var="${TARGET^^}_CONTAINER_DIR"
    DEPLOY_HOST="${!host_var:-}"
    DEPLOY_DIR="${!dir_var:-}"

    # The sources to build: the upstream branches unless the environment (or
    # deploy.local.sh) says otherwise, e.g. a local clone for unpushed work.
    : "${EDELWEISSFE_REPO:=https://github.com/Edelweiss-Numerics/EdelweissFE.git}"
    : "${EDELWEISSFE_BRANCH:=master}"
    : "${MARMOT_REPO:=https://github.com/MAteRialMOdelingToolbox/Marmot.git}"
    : "${MARMOT_BRANCH:=master}"
}

# Prints the full commit SHA of branch $2's tip in repository $1.
resolve_commit() {
    local sha
    sha=$(git ls-remote "$1" "refs/heads/$2" | cut -f1)
    [ -n "$sha" ] || { echo "ERROR: branch '$2' not found in $1" >&2; exit 1; }
    echo "$sha"
}

# Prints the edelweissfe-dev version that commit $3 (on branch $2) of
# EdelweissFE repository $1 pins, without cloning any blobs but that file.
edelweissfe_dev_version() {
    local src
    src=$(mktemp -d)
    git clone -q --no-checkout --filter=blob:none --branch "$2" "$1" "$src"
    git -C "$src" show "$3:conda/edelweissfe-dev/VERSION" | tr -d '[:space:]'
    rm -rf "$src"
}

# Parses --target=<name> out of "$@" (default: generic) and calls load_target.
parse_target() {
    local target=generic arg
    for arg in "$@"; do
        case "$arg" in --target=*) target="${arg#--target=}" ;; esac
    done
    load_target "$target"
}

# Runs "$CONTAINER_CMD exec $*" on DEPLOY_HOST's login node with the module
# loaded. Non-interactive ssh shells may lack `module`, so source the profile.
remote_container_exec() {
    local load=""
    [ -n "$CONTAINER_MODULE" ] && load="module load $CONTAINER_MODULE >/dev/null 2>&1 &&"
    ssh -q -o BatchMode=yes "$DEPLOY_HOST" \
        "source /etc/profile >/dev/null 2>&1; $load $CONTAINER_CMD exec $*"
}

require_deploy_config() {
    if [ -z "$DEPLOY_HOST" ] || [ -z "$DEPLOY_DIR" ]; then
        echo "ERROR: no deploy host/directory for target '$TARGET'. Pass --target=<leo5|leo4|vsc5|musica>" \
             "and set ${TARGET^^}_HOST and ${TARGET^^}_CONTAINER_DIR in deploy.local.sh" \
             "(see deploy.local.sh.example)." >&2
        exit 1
    fi
}
