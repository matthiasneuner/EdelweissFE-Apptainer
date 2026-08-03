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
$([ -n "$MAIL_USER" ] && echo "#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=${MAIL_USER}")

# so a failing 'edelweissfe' still fails the job (and triggers --mail-type=FAIL)
# even though its exit status is piped through tee
set -o pipefail

module load ${SINGULARITY_MODULE}
export OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
export SINGULARITYENV_OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
export APPTAINERENV_OMP_NUM_THREADS=\${SLURM_CPUS_PER_TASK}
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
