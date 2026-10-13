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
* **`--hint=nomultithread` doubles your billed/allocated CPU count, always --
  this is NOT a memory-ratio effect.** An earlier version of this note blamed
  the ~2000MB/logical-CPU ratio (256GB / 128 CPUs per node) for bumping
  `AllocCPUS` above `--cpus-per-task`. That was wrong, or at best an
  unfalsified coincidence: job 7803550 (2026-09-16) requested
  `--cpus-per-task=24 --mem=48000mb` -- exactly 24 x 2000MB, so the
  memory-ratio theory predicts NO bump -- and still got `AllocCPUS=48`
  (`scontrol show job`: `NumCPUs=48 CPUs/Task=24 ReqB:S:C:T=0:0:*:1`,
  `TRES=...,billing=48`). The real mechanism: nodes are 64 physical / 128
  logical (HT2) cores, and `--hint=nomultithread` (which `leo5_submit.sh`
  always sets, for the socket-pinning reason below) forces Slurm to reserve
  the *entire physical core* -- both hyperthread siblings -- for every
  logical CPU requested, independent of `--mem`. So billed/allocated CPUs on
  this cluster are always ~2x `--cpus-per-task` whenever nomultithread is
  set; `CPUs/Task` (and so `OMP_NUM_THREADS`) still correctly stays at what
  you asked for -- the extra logical CPUs are reserved so no other job's
  thread lands on your cores' hyperthread siblings, not wasted compute. The
  older 16-cpu-+-64GB-\>32 example that "confirmed" the memory-ratio theory
  is also consistent with this one (16 x 2 = 32), so it never actually
  distinguished the two -- this job does.
  `scripts/leo5_submit.sh`'s cpus/mem warning is still reasonable hygiene
  (LEO5 does also enforce a real 2000MB/logical-CPU memory:CPU minimum, it
  just isn't why `AllocCPUS` doubles here) but don't expect turning it off to
  change the 2x-on-nomultithread billing.
* **Threading: set `OMP_NUM_THREADS` and `PYTHON_GIL=0`, and NEVER
  `OMP_PROC_BIND`/`OMP_PLACES`.** EdelweissFE parallelizes its element loop
  with a Python `ThreadPoolExecutor` under free threading (that is what
  `PYTHON_GIL=0` is for; `OMP_NUM_THREADS` is only read to size that pool).
  It is not an OpenMP team, and OpenMP's pinning knobs break it: with
  `OMP_PROC_BIND` set, libgomp pins the process's *initial* thread to one
  core the moment an OpenMP-linked extension loads, and every Python worker
  thread created afterwards inherits that one-core mask -- so the "parallel"
  element loop runs on a single physical core, with no error and no warning.
  Found live on 2026-09-17 in jobs 7804958/7804959/7804960 (submitted with
  `OMP_PROC_BIND=close OMP_PLACES=cores`): on the compute node the main
  thread's `Cpus_allowed_list` was `3,67`, 21 of the 32 pool workers sat on
  that one core (1.69 busy cores between them), the other 12 idled 73 % of
  the time waiting for them, and `elements` cost 0.263 s/increment -- a
  same-machine A/B of the identical restart gave 0.655 s/increment pinned vs
  0.097 s unpinned. `scripts/leo5_submit.sh` and the job template therefore
  export `OMP_PROC_BIND=false` explicitly (an unset variable can be switched
  on by a module or an inherited environment) and never set `OMP_PLACES`;
  socket placement is left to the `--sockets-per-node=1 --hint=nomultithread`
  SBATCH directives, which is all the placement this workload wants. Job
  scripts written before 2026-09-17 carry the six offending exports and must
  have them removed before being reused. To verify on a running job, from
  the login node: `ssh <node> "grep Cpus_allowed_list /proc/<pid>/task/*/status
  | sort | uniq -c"` -- every thread must show the whole allocation.
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
  (EdelweissFE/Marmot branch + commit SHA, arch flags, build date, which
  manually-cloned materials are included). Read it with
  `singularity exec <sif> cat /opt/build_info.txt`, or just run
  `scripts/check_deployed_leo5.sh`.
* **Access-controlled materials** (e.g. `GCDP`, `CDP`): deliberately NOT git
  submodules of Marmot -- some materials aren't meant to be visible to
  everyone who clones the public repo. They're cloned by hand into the local
  Marmot checkout's `modules/materials/<Name>`, same as for a native build.
  If a sim needs one, pass it via `MANUAL_MATERIALS="GCDP CDP"
  ./scripts/rebuild_and_deploy_leo5.sh` -- opt-in by name, not "copy
  everything present" (the host checkout can have in-progress material dirs
  that need a not-yet-merged Marmot CMake convention and would break the
  build). `GCDP` specifically needs `CDP` too (its plasticity header).

## Updating the container (when EdelweissFE or Marmot changes)

The image is split into two layers to keep routine rebuilds cheap:

* **`edelweissfe-base.def`** -- Debian + the pinned `edelweissfe-dev` conda
  environment (EdelweissFE's meta-package; includes compilers, `mkl`, `vtk`,
  `pyvista`, Eigen/autodiff/Fastor/AMGCL). This is the slow part (big
  downloads) but changes rarely -- only when `conda/edelweissfe-dev/VERSION`
  on the EdelweissFE branch changes. The rebuild script reads that version
  and caches the base as `.build/edelweissfe-base-<version>.sif`, so a bump
  triggers a base rebuild automatically. CI builds the default version in
  `%arguments` of `edelweissfe-base.def` -- bump it there too.
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
   *fixed* target branches (`next_v26.11` / `next_v26.11` by
   default, override via `EDELWEISSFE_BRANCH`/`MARMOT_BRANCH` env vars --
   deliberately NOT whatever happens to be checked out locally, since that's
   ambient state, not a deliberate choice), reusing the cached base layer.
   Tags the image by short SHA pair, `scp`s it to `$SCRATCH/containers/`,
   repoints `edelweissfe-latest.sif`, and smoke-tests it on the login node.
   - Pass `--no-deploy` to just build+inspect locally without touching LEO5.
   - Pass `--rebuild-base` after editing `edelweissfe-base.def` -- otherwise
     the cached base for that `edelweissfe-dev` version is reused as-is.

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
