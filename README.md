# EdelweissFE Apptainer Container

This repository provides a fully packaged, ready-to-run [Apptainer](https://apptainer.org/) (formerly Singularity) container for the [EdelweissFE](https://edelweiss-numerics.github.io/EdelweissFE/) framework. 

Building EdelweissFE requires compiling several C++ libraries (Eigen, Autodiff, Fastor, Marmot). This container handles all of those dependencies internally using a Debian 13 base and Miniforge, allowing you to run simulations immediately without needing a local C++ build environment or Conda setup.

---

## Prerequisites

To use this container, you only need to have Apptainer installed on your host system (usually a Linux machine or an HPC cluster). 

* [Install Apptainer](https://apptainer.org/docs/admin/main/installation.html)

---

## Getting the Container

You do not need to build the container yourself. The latest compiled `.sif` (Singularity Image Format) file is automatically generated and attached to our releases.

1. Navigate to the **Releases** page of this GitHub repository.
2. Download the latest `edelweissfe-debian-13.sif` file.
3. Place the `.sif` file in your working directory or a central location on your machine.

---

## Usage

Apptainer natively integrates with your host system. By default, it automatically mounts your current working directory, meaning the container can read your input files and write output files exactly where you execute the command.

### Running a Simulation

To run an EdelweissFE simulation, treat the `.sif` file as if it were the `edelweissfe` executable:

```bash
# Basic execution
apptainer run edelweissfe-debian-13.sif my_simulation_input.inp
```

---

## What's inside

`edelweissfe-debian-13.def` builds, from source, on top of a Debian 13 + Miniforge base:

* Eigen 3.4.0, autodiff v1.1.0, Fastor (header-only) -- Marmot's dependencies
* [Marmot](https://github.com/MAteRialMOdelingToolbox/Marmot), branch `next_v26.11`
* [EdelweissFE](https://github.com/EdelweissFE/EdelweissFE), branch `feat/amr-recovery-marker` --
  currently cloned from [matthiasneuner's fork](https://github.com/matthiasneuner/EdelweissFE)
  since this branch isn't merged/pushed to the org repo yet; switch the `.def` file back to the
  org URL once it lands on `next_v26.11`

The image build hard-fails if the Marmot-backed Cython extensions
(`marmotelement`, `marmotmaterialhypoelasticwrapper`) don't compile --
EdelweissFE's `setup.py` otherwise lets individual extensions fail silently,
which would produce a container that looks fine but is missing Marmot
materials/elements at runtime.

To track a different EdelweissFE/Marmot branch (or release), edit the two
`git clone --branch ...` lines in the `.def` file.

## Performance: compilation flags

Compiled hot paths (Marmot, and several of EdelweissFE's Cython extensions)
are built with an explicit `-march=icelake-server -mtune=icelake-server`,
targeting the Intel Xeon Platinum 8358 ("Ice Lake-SP") CPUs on LEO5's compute
nodes. This is set explicitly (via `ARCH_FLAGS` near the top of the `.def`
file's `%post` section) rather than using `-march=native`, because the image
is built on a generic CI runner -- `-march=native` there would target the
*runner's* CPU, not the cluster the image actually runs on.

If you build this image for a different cluster, change `ARCH_FLAGS` in the
`.def` file to match its CPU (and, for Marmot, `MARMOT_MARCH_NATIVE=ON` is
appropriate instead if you're building locally on the exact target machine).

---

## Running on LEO5 (Uni Innsbruck)

LEO5 uses Slurm and only exposes Apptainer/Singularity via the module system
(there is no `apptainer`/`singularity` binary on `PATH` by default):

```bash
module load singularityce/4.3.0-python-3.11.9-gcc-13.3.0-n5qceek
```

SIF images built by Apptainer run fine under SingularityCE (same image
format), so the `.sif` from this repo's Releases page works as-is.

A ready-to-adapt job script is provided as
[`leo5_job.sh.template`](leo5_job.sh.template) -- copy it next to your
`.sif` and input files under `$SCRATCH` (large, high-performance storage;
avoid running large jobs out of `$HOME`, which is small and backup-oriented),
rename it, and submit:

```bash
cp leo5_job.sh.template my_job.sh
sbatch my_job.sh my_simulation_input.inp
```

Key points baked into the template:

* `-p std` (default partition, max 10 days) or `-p test` (max 10h) for quick
  smoke runs before committing to a long allocation.
* `--cpus-per-task=64` requests one full node's *physical* cores (LEO5
  reports 128 logical CPUs per node due to hyperthreading; oversubscribing
  HT usually doesn't help this compute-bound OpenMP code -- benchmark on
  `test` before scaling up).
* `OMP_NUM_THREADS` is exported both plainly and as `SINGULARITYENV_...` /
  `APPTAINERENV_...` so it reaches the process inside the container
  regardless of which module name resolved.
* `PYTHON_GIL=0` is set inside the container environment to keep
  EdelweissFE's free-threaded parallel element loops enabled.
* `singularity exec --bind "$(pwd)"` -- LEO5's Singularity install only
  auto-binds `$HOME`, not `$SCRATCH`. Without the explicit `--bind`, the
  container can't see your input files even though `apptainer run` on your
  own machine "just works" (confirmed by testing on LEO5 directly).
