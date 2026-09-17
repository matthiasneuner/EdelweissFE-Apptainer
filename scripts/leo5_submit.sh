#!/bin/bash
# Generates and submits a Slurm job for an EdelweissFE .inp against the
# centrally-deployed edelweissfe-latest.sif, inside a project directory
# already synced to LEO5 (see leo5_sync.sh push).
#
# Usage: scripts/leo5_submit.sh <project-dir-name> <input.inp> [partition] [cpus] [mem] [time]
# Override the notification address via MAIL_USER (empty disables mail notifications).
set -euo pipefail

PROJECT="${1:?project directory name (relative to workspace root / $SCRATCH)}"
INPUT="${2:?input .inp file, relative to the project directory}"
PARTITION="${3:-std}"
CPUS="${4:-64}"
MEM="${5:-240000mb}"
TIME="${6:-1-00:00:00}"

LEO5_HOST="${LEO5_HOST:-c8441141@leo5.uibk.ac.at}"
REMOTE_DIR="${LEO5_SCRATCH:-/scratch/c8441141}/$PROJECT"
CONTAINER="${LEO5_SCRATCH:-/scratch/c8441141}/containers/edelweissfe-latest.sif"
SINGULARITY_MODULE="${SINGULARITY_MODULE:-singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek}"
MAIL_USER="${MAIL_USER:-matthias.neuner@uibk.ac.at}"
JOB_NAME="$(basename "$INPUT" .inp)"
LOG_NAME="${PROJECT}_${JOB_NAME}.log"

# LEO5's std/test partition nodes are 256GB / 128 logical CPUs = 2000MB/CPU.
# Slurm's scheduler bumps the actual CPU allocation up to whatever this ratio
# requires to back the requested memory, even though CPUs/Task (and so
# OMP_NUM_THREADS) stays at what you asked for -- meaning the extra cores are
# billed/reserved but sit idle, unused by this job. Confirmed on job 7298015:
# asked for 16 cpus + 64GB, got AllocCPUS=32 while CPUs/Task stayed 16.
MEM_MB=$(echo "$MEM" | sed -E 's/([0-9]+)[gG][bB]?/\1000/; s/([0-9]+)[mM][bB]?/\1/; s/[^0-9]//g')
MB_PER_CPU=2000
MIN_CPUS_FOR_MEM=$(( (MEM_MB + MB_PER_CPU - 1) / MB_PER_CPU ))
if [ "$CPUS" -lt "$MIN_CPUS_FOR_MEM" ]; then
    echo "WARNING: requesting ${MEM} with only --cpus-per-task=${CPUS} -- LEO5's" \
         "~${MB_PER_CPU}MB/CPU ratio means Slurm will actually allocate/bill" \
         "~${MIN_CPUS_FOR_MEM} cpus to back that memory, but OMP_NUM_THREADS stays" \
         "at ${CPUS} (the other $((MIN_CPUS_FOR_MEM - CPUS)) sit idle). Consider" \
         "raising cpus to ${MIN_CPUS_FOR_MEM}, or lowering mem, to avoid wasting" \
         "allocated cores."
fi

# This job script pins to a single socket (--sockets-per-node=1
# --hint=nomultithread, see below) -- LEO5's sockets are 32 physical cores
# each, so a request above that can never be satisfied within one socket.
CORES_PER_SOCKET=32
if [ "$CPUS" -gt "$CORES_PER_SOCKET" ]; then
    echo "WARNING: --cpus-per-task=${CPUS} exceeds LEO5's ${CORES_PER_SOCKET}" \
         "physical cores/socket, but this job script pins to a single socket" \
         "(--sockets-per-node=1 --hint=nomultithread) -- the request will" \
         "likely fail to schedule or silently span sockets. Use" \
         "${CORES_PER_SOCKET} or fewer."
fi

JOB_SCRIPT=$(mktemp)
trap 'rm -f "$JOB_SCRIPT"' EXIT
cat > "$JOB_SCRIPT" <<EOF
#!/bin/bash
#SBATCH --job-name=${PROJECT}_${JOB_NAME}
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=${CPUS}
#SBATCH --mem=${MEM}
#SBATCH --time=${TIME}
#SBATCH -p ${PARTITION}
#SBATCH -o slurm-%j.out
#SBATCH -e slurm-%j.err
# LEO5 nodes are 2 sockets x 32 physical cores (HT2, 128 logical cpus/node).
# Cross-socket NUMA traffic hurts this workload -- stay on one physical CPU
# package: --sockets-per-node=1 keeps the whole allocation within one socket,
# --hint=nomultithread avoids being handed HT sibling cpus instead of distinct
# physical cores (only sane up to --cpus-per-task=32, one socket's worth).
#SBATCH --sockets-per-node=1
#SBATCH --hint=nomultithread
$([ -n "$MAIL_USER" ] && echo "#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=${MAIL_USER}")

# so a failing 'edelweissfe' still fails the job (and triggers --mail-type=FAIL)
# even though its exit status is piped through tee
set -o pipefail

module load ${SINGULARITY_MODULE}
export OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
export SINGULARITYENV_OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
export APPTAINERENV_OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
# Do NOT pin threads with OMP_PROC_BIND/OMP_PLACES. EdelweissFE's element loop
# is a Python ThreadPoolExecutor under free threading (PYTHON_GIL=0), not an
# OpenMP team: with OMP_PROC_BIND set, libgomp pins the process's INITIAL
# thread to one core the moment it loads, and every Python worker created
# after that inherits that one-core mask -- the "parallel" element loop then
# runs on a single physical core. Seen live on 2026-09-17 (jobs 7804958/59/60:
# 21 of 32 workers confined to cpus 3,67; elements 0.263 s/increment, 6x
# slower than unpinned on the same model). Socket placement is done by the
# SBATCH directives above, which is all the pinning this workload wants.
# Set to false explicitly rather than left unset, so nothing inherited from
# the login environment or a module can switch it on inside the container.
export OMP_PROC_BIND=false
export SINGULARITYENV_OMP_PROC_BIND=false
export APPTAINERENV_OMP_PROC_BIND=false
unset OMP_PLACES SINGULARITYENV_OMP_PLACES APPTAINERENV_OMP_PLACES
export SINGULARITYENV_PYTHON_GIL=0
export APPTAINERENV_PYTHON_GIL=0
# Python fully buffers stdout when it's not a TTY (e.g. redirected to a log
# file) -- without this, the log file stays empty for long stretches and
# only catches up in bursts, or not at all if the job is killed/times out.
export PYTHONUNBUFFERED=1
export SINGULARITYENV_PYTHONUNBUFFERED=1
export APPTAINERENV_PYTHONUNBUFFERED=1

# LEO5's Singularity install only auto-binds \$HOME, not \$SCRATCH.
# Log written explicitly to ${LOG_NAME} in addition to Slurm's own -o/-e
# (which land in slurm-<jobid>.out/.err) -- tail -f ${LOG_NAME} to follow.
singularity exec --bind "\$(pwd)" ${CONTAINER} edelweissfe ${INPUT} 2>&1 | tee "${LOG_NAME}"
EOF

REMOTE_JOB_SCRIPT="job_${JOB_NAME}.sh"
scp -o BatchMode=yes "$JOB_SCRIPT" "$LEO5_HOST:$REMOTE_DIR/$REMOTE_JOB_SCRIPT"
ssh -o BatchMode=yes "$LEO5_HOST" "cd '$REMOTE_DIR' && sbatch $REMOTE_JOB_SCRIPT"
