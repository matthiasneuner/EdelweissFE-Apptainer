# LEO5 simulation workflow

This is the reference for running EdelweissFE simulations on LEO5 (Uni
Innsbruck HPC) through this container, on a recurring basis. Read this first
when picking the workflow back up in a new session.

## Facts that don't change often

* Login: `ssh c8441141@leo5.uibk.ac.at` -- key-based, no 2FA prompt in the
  way (confirmed working non-interactively, e.g. `ssh -o BatchMode=yes ...`).
* Compute nodes: Intel Xeon Platinum 8358 ("Ice Lake-SP"), 64 physical / 128
  logical (HT2) cores per node, full AVX-512.
* Partitions: `std` (default, max 10-00:00:00) and `test` (max 10:00:00, good
  for smoke tests) -- both offer up to 64 physical cores/node.
* No `apptainer`/`singularity` on `PATH` by default; every remote command
  needs `module load singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek`
  first (the scripts below already do this for you).
* **LEO5's Singularity install only auto-binds `$HOME`, not `$SCRATCH`.**
  Any `singularity exec`/`run` touching files under `$SCRATCH` needs an
  explicit `--bind`, or it'll silently miss files that are clearly right
  there in the working directory (confirmed by testing -- this bit us once).

## Where things live

* **Container**, centrally, versioned by source commit:
  `$SCRATCH/containers/edelweissfe-<edelweissfe-sha>-<marmot-sha>.sif`, with
  `$SCRATCH/containers/edelweissfe-latest.sif` as a symlink to whichever one
  is current. Jobs should reference `edelweissfe-latest.sif`, not a per-run
  copy -- don't duplicate a 1.4GB file into every project directory.
* **Simulation projects**: each lives in its own top-level directory in this
  workspace (matching the existing convention, e.g. `Pryout_anchorwashernut/`,
  `Particle-Taylor-Impact-Test/`) with `.inp` files, `mesh/`/`incfiles/`, and
  results side by side. Mirrored 1:1 to `$SCRATCH/<project-dir-name>/` on
  LEO5 -- see `scripts/leo5_sync.sh`.
* **Build provenance**: every image has `/opt/build_info.txt` baked in
  (EdelweissFE/Marmot branch + commit SHA, arch flags, build date). Read it
  with `singularity exec <sif> cat /opt/build_info.txt`, or just run
  `scripts/check_deployed_leo5.sh`.

## Updating the container (when EdelweissFE or Marmot changes)

The image is split into two layers to keep routine rebuilds cheap:

* **`edelweissfe-base.def`** -- Debian + conda/pip deps (`mkl`, `vtk`,
  `pyvista`, ...) + Eigen/autodiff/Fastor. This is the slow part (conda solve
  + big downloads) but changes rarely -- only when EdelweissFE's
  `conda_requirements.txt`/`pip_requirements.txt` (or `edelweissfe-base.def`
  itself) changes.
* **`edelweissfe-debian-13.def`** -- `Bootstrap: localimage` on top of the
  cached base, clones + builds Marmot and EdelweissFE only. This is what
  changes on every routine update, and it's what stays fast: ~7 minutes
  (mostly Marmot's C++ compile, `-j$(nproc)`) instead of redoing the whole
  stack from scratch every time.

Workflow:

1. Pull/update the local `EdelweissFE` and/or `Marmot` checkouts to whatever
   commit should ship.
2. `scripts/check_deployed_leo5.sh` -- compare local HEADs against what's
   deployed, to confirm a rebuild is actually needed.
3. `scripts/rebuild_and_deploy_leo5.sh` -- builds the top layer against the
   *fixed* target branches (`feat/amr-recovery-marker` / `next_v26.11` by
   default, override via `EDELWEISSFE_BRANCH`/`MARMOT_BRANCH` env vars --
   deliberately NOT whatever happens to be checked out locally, since that's
   ambient state, not a deliberate choice), reusing the cached base layer.
   Tags the image by short SHA pair, `scp`s it to `$SCRATCH/containers/`,
   repoints `edelweissfe-latest.sif`, and smoke-tests it on the login node.
   - Pass `--no-deploy` to just build+inspect locally without touching LEO5.
   - Pass `--rebuild-base` after editing `edelweissfe-base.def` or the
     conda/pip requirements -- otherwise the cached base is reused as-is.

**Don't run two rebuilds concurrently** -- both use the same local
`.build/apptainer-cache`, and overlapping `apptainer build --fakeroot`
invocations against it can corrupt each other's state. Wait for one to finish
(check `ps aux | grep apptainer`) before starting another.

This local path is deliberately **separate** from
`.github/workflows/build-apptainer.yml`, which is the "official" path (clones
from GitHub, builds both layers on CI with the base cached via
`actions/cache`, publishes a GitHub Release) -- use that once
`feat/amr-recovery-marker` and `feat/configurable-arch-flags` are actually
merged upstream. Until then, the local rebuild/deploy script is the fast
iteration loop.

Note: this container has no GPU support baked in and doesn't need any --
EdelweissFE is CPU/OpenMP-only. Don't request GPU nodes/gres for these jobs.

## Running a simulation

```bash
# 1. push the project's .inp/mesh/etc. to $SCRATCH
scripts/leo5_sync.sh push Pryout_anchorwashernut

# 2. submit (defaults: partition std, 64 cpus, 240000mb, 1 day)
scripts/leo5_submit.sh Pryout_anchorwashernut AnchorPryOut_EdelweissFE.inp
# or override: leo5_submit.sh <project> <input.inp> <partition> <cpus> <mem> <time>
scripts/leo5_submit.sh Pryout_anchorwashernut AnchorPryOut_EdelweissFE.inp test 8 8000mb 00:10:00

# 3. monitor (read-only, safe to run directly)
ssh c8441141@leo5.uibk.ac.at "squeue -u c8441141"
ssh c8441141@leo5.uibk.ac.at "sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed"

# 4. once done, pull results back
scripts/leo5_sync.sh pull Pryout_anchorwashernut
```

`sbatch`/`scancel`/pushing new files are state-changing -- always confirmed
with you before running, per the standing workflow rule. `squeue`/`sacct`/log
inspection are read-only and safe to run directly.

## Known gaps (not fixed here, your call)

* `CDP`, `GCDP`, `GosfordSandstone` are real repos
  (`git.uibk.ac.at:c8441141/...`) but aren't wired into Marmot as git
  submodules -- a plain clone (this container included) won't have them.
* `feat/amr-recovery-marker` (EdelweissFE) and `feat/configurable-arch-flags`
  only exist on the `mn` fork, not the org repos yet.
