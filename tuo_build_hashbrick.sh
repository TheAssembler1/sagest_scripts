#!/usr/bin/env bash
set -exuo pipefail

SRC=/p/lustre5/lewis153/src

SCRIPT_PATH="$(realpath "$0")"

if [ -f "./configure" ] && [ -f "./cudaToHip.pl" ]; then
    HASHBRICK_DIR="$(pwd)"
elif [ -f "$SRC/hashbrick/configure" ] && [ -f "$SRC/hashbrick/cudaToHip.pl" ]; then
    HASHBRICK_DIR="$SRC/hashbrick"
else
    echo "ERROR: could not find hashbrick's configure + cudaToHip.pl, either" >&2
    echo "       in the current directory or at $SRC/hashbrick." >&2
    echo "       Run this script from inside the hashbrick repo, or fix SRC above." >&2
    exit 1
fi
cd "$HASHBRICK_DIR"
echo "Building HashBrick in: $HASHBRICK_DIR"

if [ -d .git ]; then
    echo "Cleaning git repo in $HASHBRICK_DIR"
    git checkout -- .          # discard changes to tracked files (e.g. from a prior cudaToHip.pl run)
    git checkout automated_hip # make sure we're on the right branch before cleaning/pulling

    CLEAN_EXCLUDES=()
    case "$SCRIPT_PATH" in
        "$HASHBRICK_DIR"/*)
            SCRIPT_REL="${SCRIPT_PATH#"$HASHBRICK_DIR"/}"
            echo "Script is inside the repo at '$SCRIPT_REL' -- excluding it from git clean."
            CLEAN_EXCLUDES=(-e "/$SCRIPT_REL")
            ;;
    esac
    git clean -xdf "${CLEAN_EXCLUDES[@]}"   # remove untracked/ignored files (build artifacts, generated Hip files, etc.)

    git fetch origin automated_hip
    git pull --ff-only origin automated_hip   # fail loudly instead of silently merging/diverging
else
    echo "WARNING: $HASHBRICK_DIR is not a git repo; skipping git clean/pull." >&2
fi

module load rocmcc/6.4.3-magic   # version specific
module load cray-dsmml
module load cray-openshmemx/11.8.0
module load craype-accel-amd-gfx942
module list

export MPICH_GPU_SUPPORT_ENABLED=1
export MPICH_SMP_SINGLE_COPY_MODE=NONE

perl cudaToHip.pl -r -p .

./configure \
    --with-mpi=tuolumne \
    --with-cgns=none \
    --with-hip \
    --with-computer=tuolumne

pushd lib/test/HashBrick
make -j16 GPU=TRUE HIPARCH="--offload-arch=gfx942" run
popd
lewis153@tuolumne1010:hashbrick$ vim build.sh
lewis153@tuolumne1010:hashbrick$ cat build.sh
#!/usr/bin/env bash
set -exuo pipefail

SRC=/p/lustre5/lewis153/src

SCRIPT_PATH="$(realpath "$0")"

if [ -f "./configure" ] && [ -f "./cudaToHip.pl" ]; then
    HASHBRICK_DIR="$(pwd)"
elif [ -f "$SRC/hashbrick/configure" ] && [ -f "$SRC/hashbrick/cudaToHip.pl" ]; then
    HASHBRICK_DIR="$SRC/hashbrick"
else
    echo "ERROR: could not find hashbrick's configure + cudaToHip.pl, either" >&2
    echo "       in the current directory or at $SRC/hashbrick." >&2
    echo "       Run this script from inside the hashbrick repo, or fix SRC above." >&2
    exit 1
fi
cd "$HASHBRICK_DIR"
echo "Building HashBrick in: $HASHBRICK_DIR"

if [ -d .git ]; then
    echo "Cleaning git repo in $HASHBRICK_DIR"
    git checkout -- .          # discard changes to tracked files (e.g. from a prior cudaToHip.pl run)
    git checkout automated_hip # make sure we're on the right branch before cleaning/pulling

    CLEAN_EXCLUDES=()
    case "$SCRIPT_PATH" in
        "$HASHBRICK_DIR"/*)
            SCRIPT_REL="${SCRIPT_PATH#"$HASHBRICK_DIR"/}"
            echo "Script is inside the repo at '$SCRIPT_REL' -- excluding it from git clean."
            CLEAN_EXCLUDES=(-e "/$SCRIPT_REL")
            ;;
    esac
    git clean -xdf "${CLEAN_EXCLUDES[@]}"   # remove untracked/ignored files (build artifacts, generated Hip files, etc.)

    git fetch origin automated_hip
    git pull --ff-only origin automated_hip   # fail loudly instead of silently merging/diverging
else
    echo "WARNING: $HASHBRICK_DIR is not a git repo; skipping git clean/pull." >&2
fi

module load rocmcc/6.4.3-magic   # version specific
module load cray-dsmml
module load cray-openshmemx/11.8.0
module load craype-accel-amd-gfx942
module list

export MPICH_GPU_SUPPORT_ENABLED=1
export MPICH_SMP_SINGLE_COPY_MODE=NONE

perl cudaToHip.pl -r -p .

./configure \
    --with-mpi=tuolumne \
    --with-cgns=none \
    --with-hip \
    --with-computer=tuolumne

pushd lib/test/HashBrick
make -j16 GPU=TRUE HIPARCH="--offload-arch=gfx942" run
popd
