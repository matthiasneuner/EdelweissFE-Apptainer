# EdelweissFE Apptainer Container

This repository provides a fully packaged, ready-to-run [Apptainer](https://apptainer.org/) (formerly Singularity) container for the [EdelweissFE](https://edelweiss-numerics.github.io/EdelweissFE/) framework, linked against [Marmot](https://github.com/MAteRialMOdelingToolbox/Marmot).

Building EdelweissFE with Marmot requires a pinned conda environment plus compiling Marmot. This container does both, on a Debian 13 base with Miniforge, allowing you to run simulations immediately without needing a local C++ build environment or Conda setup.

---

## Getting the Container

You do not need to build the container yourself. The latest `.sif` (Singularity Image Format) file is built by CI and attached to the releases:

1. Navigate to the **Releases** page of this GitHub repository.
2. Download the latest `edelweissfe-debian-13.sif` file.
3. Place it in your working directory or a central location.

You only need Apptainer (or SingularityCE, which reads the same images) on the host: [Install Apptainer](https://apptainer.org/docs/admin/main/installation.html).

The release image is compiled for `-march=x86-64-v3` (any x86 CPU with AVX2/FMA). For the best performance on a specific cluster, build an image for its CPU (see [Building for a cluster](#building-for-a-cluster)).

## Usage

Treat the `.sif` file as if it were the `edelweissfe` executable:

```bash
apptainer run edelweissfe-debian-13.sif my_simulation_input.inp
```

Apptainer mounts your home directory and the current working directory by default on most installations, so the container reads and writes files where you run it. HPC installations often do not mount the large work file systems (`$SCRATCH`, `$DATA`, ...): bind them explicitly (see below).

---

## What's inside

* `edelweissfe-base.def`: Debian 13 + Miniforge + EdelweissFE's pinned development
  environment, the `edelweissfe-dev` meta-package from the Edelweiss conda channel
  (`https://repo.prefix.dev/matthiasneuner/edelweiss`), at `/opt/edelweissfe-env`. It pins
  everything exactly as EdelweissFE's `conda-lock.yml`: free-threaded Python 3.14, compilers,
  cmake, MKL, vtk/pyvista, and Eigen/autodiff/Fastor/AMGCL. Nothing is compiled in this layer;
  it only changes with the `edelweissfe-dev` version.
* `edelweissfe-debian-13.def` builds, on top of it:
  * [Marmot](https://github.com/MAteRialMOdelingToolbox/Marmot), branch `master`
  * [EdelweissFE](https://github.com/Edelweiss-Numerics/EdelweissFE), branch `master`

  Repositories, branches, commits, CPU flags and extra materials are build arguments
  (`%arguments` in the `.def` file); the defaults are what CI builds.

The image build hard-fails if the Marmot-backed Cython extensions
(`marmotelement`, `marmothypoelastic`, `marmotgradientenhancedhypoelastic`) or the
`amgcl`/`pardiso` solver bindings don't compile --
EdelweissFE's `setup.py` otherwise lets individual extensions fail silently,
which would produce a container that looks fine but is missing Marmot
materials/elements at runtime.

Every image carries its provenance in `/opt/build_info.txt` (commits, CPU flags,
`edelweissfe-dev` version, included materials):

```bash
apptainer exec edelweissfe-debian-13.sif cat /opt/build_info.txt
```

---

## Building for a cluster

Compiled hot paths (Marmot and EdelweissFE's Cython extensions) are built for one
CPU, chosen explicitly. Never `-march=native`: the image is built on a different
machine than the one it runs on. `scripts/_targets.sh` holds the targets:

| Target    | CPU                                     | `-march`         | Container runtime on the cluster      |
| :-------- | :-------------------------------------- | :--------------- | :------------------------------------ |
| `leo5`    | Intel Xeon Platinum 8358 (Ice Lake-SP)  | `icelake-server` | `singularityce/4.3.0-...` module      |
| `leo4`    | Intel Xeon E5-2690 v4 (Broadwell)       | `broadwell`      | `singularity/3.x` module              |
| `vsc5`    | AMD EPYC 7713 (Zen 3)                   | `znver3`         | `apptainer/1.1.9-...` module          |
| `musica`  | AMD EPYC 9654 (Zen 4)                   | `znver4`         | system Apptainer (1.5.2), no module   |
| `generic` | any x86 with AVX2/FMA (the CI image)    | `x86-64-v3`      | --                                    |

An image built for an AVX-512 CPU dies with `SIGILL` on a CPU without it.

Build on a Linux machine with Apptainer >= 1.2 (`%arguments`/`--build-arg`, `--fakeroot`
builds), not on the cluster:

```bash
cp deploy.local.sh.example deploy.local.sh    # once: your logins, container directories, materials
scripts/build.sh --target=vsc5                 # -> .build/edelweissfe-<ef>-<marmot>-vsc5.sif
scripts/deploy.sh --target=vsc5 .build/edelweissfe-<ef>-<marmot>-vsc5.sif
scripts/check_deployed.sh --target=vsc5       # upstream tips vs. the deployed image
```

* `build.sh` builds the **upstream** branch tips (`EDELWEISSFE_BRANCH`/`MARMOT_BRANCH`,
  default `master`), resolved to commits and pinned -- never the state of a local
  checkout. Point `EDELWEISSFE_REPO`/`MARMOT_REPO` at a local clone to build unpushed work.
  Images are named by both commits and the target, and are not rebuilt if present.
* The base layer is cached as `.build/edelweissfe-base-<version>.sif` and rebuilt when the
  `edelweissfe-dev` version changes, or with `--rebuild-base`. Don't run two builds at
  once: they share `.build/apptainer-cache`.
* `deploy.sh` copies the image to `<TARGET>_CONTAINER_DIR`, checks the checksum, points
  `edelweissfe-latest.sif` at it and smoke-tests it on the login node (CLI, then
  `scripts/smoke_test.py`: Marmot/AMGCL/Pardiso imports, free threading; CI runs the same
  test on the release image). With `--via-host=<build-host>` it streams an image
  that lives on the build host through the machine you run it on -- for clusters the
  build host cannot log in to (e.g. two-factor login with a ControlMaster connection).
* **Access-controlled Marmot materials** (e.g. `GCDP`, `CDP`) are deliberately not
  submodules of the public Marmot repository. Clone them by hand into a directory and set
  `MANUAL_MATERIALS="GCDP CDP"` and `MANUAL_MATERIALS_DIR` (in `deploy.local.sh`); they are
  copied into the build by name, and the build fails if one is missing. `GCDP` needs `CDP`.

---

## Running on an HPC cluster

* **Load the runtime**: clusters usually provide Apptainer/Singularity only as a module
  (see the table above). SIF images built by Apptainer run under SingularityCE as well.
* **Bind the work file system**: `apptainer exec --bind "$(pwd)" ...` (or `--bind
  "$SCRATCH"`). Without it the container silently doesn't see your input files under a
  non-default file system.
* **Threads**: set `OMP_NUM_THREADS` to the job's CPU count and `PYTHON_GIL=0`, and pass
  them into the container (`APPTAINERENV_*`/`SINGULARITYENV_*`, or `--env`).
  EdelweissFE parallelizes its element loop with a free-threaded Python thread pool,
  sized by `OMP_NUM_THREADS`.
* **Never set `OMP_PROC_BIND` or `OMP_PLACES`**, and export `OMP_PROC_BIND=false` so no
  module or inherited environment turns it on. The element loop is a Python thread pool,
  not an OpenMP team: with `OMP_PROC_BIND` set, libgomp pins the initial thread to one
  core when an OpenMP extension loads, every Python worker created afterwards inherits
  that one-core mask, and the "parallel" loop runs on a single core, without any warning
  (measured 6x slower). Do placement with the scheduler instead (e.g. Slurm
  `--sockets-per-node=1 --hint=nomultithread`). To check a running job:
  `grep Cpus_allowed_list /proc/<pid>/task/*/status | sort | uniq -c` -- every thread
  must show the whole allocation.
* `PYTHONUNBUFFERED=1` keeps a redirected log file current.
* No GPU support is needed or included; EdelweissFE is CPU-only.

A minimal Slurm job:

```bash
#!/bin/bash
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
set -o pipefail
module load <apptainer-or-singularity-module>
export APPTAINERENV_OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK SINGULARITYENV_OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export APPTAINERENV_PYTHON_GIL=0 SINGULARITYENV_PYTHON_GIL=0
export OMP_PROC_BIND=false APPTAINERENV_OMP_PROC_BIND=false SINGULARITYENV_OMP_PROC_BIND=false
export APPTAINERENV_PYTHONUNBUFFERED=1 SINGULARITYENV_PYTHONUNBUFFERED=1
apptainer exec --bind "$(pwd)" /path/to/edelweissfe-latest.sif edelweissfe "$1" 2>&1 | tee "${1%.inp}.log"
```
