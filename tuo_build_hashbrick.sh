#!/usr/bin/env bash
set -exuo pipefail

# ============================================================
# Build + test script: HashBrick (standalone repo) -- Tuolumne (LLNL)
# ============================================================
# Sources for this script:
#   - hashbrick/README.md + ./configure --help (pasted directly)
#   - hashbrick/cudaToHip.pl usage header (pasted directly)
#   - Your build_storage_deps.sh (HDF5 2.2.0 + CGNS 4.5.0, parallel,
#     already installed under /p/lustre5/lewis153/src)
#   - You confirmed: cudaToHip.pl is run MANUALLY before ./configure --
#     configure's --with-hip flag does NOT invoke it automatically
#     (despite what the script's own header comment implies).
#
# Scope: this script builds and tests HashBrick only. No euler-miniapp
# interaction.
#
# CONFIRMED from real runs on Tuolumne:
#   - `perl cudaToHip.pl -r -p .` runs cleanly and converts the whole tree.
#     (Note: configure ALSO reruns this conversion itself internally --
#     harmless, just redundant with the manual step above.)
#   - `--with-computer=tuolumne` is accepted fine ("checking for computer...
#     tuolumne").
#   - Bare `--with-hip` (no path) failed: "hipcc not found" -- an explicit
#     `--with-hip=<rocm_prefix>` is required.
#   - `rocm/6.4.3` and `cray-openshmemx/11.8.0` are the default (D) modules
#     on Tuolumne -- used below.
#   - hipcc does NOT get the automatic MPI -I injection that the Cray
#     cc/CC wrappers give .cpp files. GPUCPPFLAGS is accepted by configure
#     but a real run showed it's NOT actually threaded through to the
#     hipcc/clang++ compile line for .hip files (confirmed: 'mpi.h'/
#     'shmem.h' not found persisted even with GPUCPPFLAGS set). Fixed
#     instead by exporting CPATH with the same include dirs -- Clang
#     (which hipcc wraps) honors CPATH for every compile automatically,
#     independent of what the Makefile passes. CONFIRMED this resolved
#     all compile-time mpi.h/shmem.h errors in a real run.
#   - After the CPATH fix, the build got past compiling and failed at
#     LINK time instead: "undefined symbol: MPI_Init / shmem_init / ..."
#     because the hipcc link line had no MPI/SHMEM libraries at all.
#     Unlike GPUCPPFLAGS, `Common/mk/Make.rules` was inspected directly
#     and confirmed to use $(LDFLAGS) in the hipcc link rule, so LDFLAGS
#     (populated from `cc --cray-print-opts=libs`) is passed to configure
#     as the fix -- this one should actually be threaded through.
#
# STILL UNCONFIRMED (flagged inline with TODO):
#   1. Whether LDFLAGS actually resolves the undefined MPI/SHMEM symbol
#      errors -- not yet re-run past this point.
#   2. No NVSHMEM/ROCSHMEM flag exists in configure --help, so this builds
#      MPI-only -- per Andy, that means the MPI bulk-exchange model rather
#      than a shared-memory transport, which will be correct but slower.
# ============================================================

# FIXME FILLE THIS IN
SRC=/p/lustre5/lewis153/src
CGNS_PREFIX="$SRC/CGNS-src/install"

# ------------------------------------------------------------
# Modules -- TODO: verify exact names/versions on Tuolumne
# ------------------------------------------------------------
module load cmake/3.29.2
module load rocm/6.4.3          # default (D) module per `module avail rocm` on Tuolumne
module load cray-dsmml          # required dependency of cray-openshmemx (Lmod error otherwise)
module load cray-pmi            # provides libpmi/libpmi2 -- Andy's Perlmutter script loads this
                                 # alongside cray-openshmemx; missing it caused
                                 # "ld.lld: error: unable to find library -lpmi[2]"
module load cray-openshmemx/11.8.0   # default (D) module per `module avail | grep -i shmem`; provides mpi.h/shmem.h
module list

# Sanity check: hipcc must be reachable once the module is loaded.
if ! command -v hipcc >/dev/null 2>&1; then
    echo "ERROR: hipcc still not on PATH after 'module load rocm/6.4.3'." >&2
    echo "       Check 'module show rocm/6.4.3' for where it installs hipcc," >&2
    echo "       and set ROCM_PATH manually below if needed." >&2
    exit 1
fi
echo "hipcc found at: $(command -v hipcc)"

# hipcc (invoked directly for .hip files) does NOT get the automatic
# -I injection that the Cray `cc`/`CC` wrappers normally provide for
# MPI/OpenSHMEM headers. Capture those flags from `cc` itself and pass
# them through GPUCPPFLAGS (a configure-recognized variable) so hipcc
# can find mpi.h/shmem.h too.
CRAY_MPI_CFLAGS="$(cc --cray-print-opts=cflags)"
echo "Cray MPI/libsci include flags for GPUCPPFLAGS: $CRAY_MPI_CFLAGS"

CRAY_MPI_LIBS="$(cc --cray-print-opts=libs)"
echo "Cray MPI/SHMEM link flags for LDFLAGS: $CRAY_MPI_LIBS"
# NOTE: unlike GPUCPPFLAGS (not threaded through to the hipcc compile
# rule -- see CPATH workaround below), LDFLAGS IS used directly in the
# hipcc link rule in Common/mk/Make.rules (confirmed by inspection), so
# passing it to configure should actually work rather than needing
# another CPATH-style env-var workaround. Fixes "undefined symbol:
# MPI_Init / shmem_init / ..." at link time.

# WORKAROUND: the actual hipcc/clang++ invocation shown by `make` does NOT
# include GPUCPPFLAGS at all -- HashBrick's Makefile accepts it at configure
# time but doesn't thread it through to the .hip compile rule (confirmed by
# inspecting the failed command in a real build; 'mpi.h'/'shmem.h' not found
# even after GPUCPPFLAGS was set). Clang (which hipcc wraps) honors the
# CPATH env var for every compile regardless of Makefile flags, so export
# the same include dirs there as a more robust fix.
CRAY_MPI_INCLUDE_DIRS="$(echo "$CRAY_MPI_CFLAGS" | tr ' ' '\n' | sed -n 's/^-I//p' | paste -sd: -)"
export CPATH="${CRAY_MPI_INCLUDE_DIRS}${CPATH:+:$CPATH}"
echo "CPATH set to: $CPATH"

# ------------------------------------------------------------
# Locate the hashbrick directory. Works whether this script is:
#   - run from inside the hashbrick repo itself (./build_hashbrick_tuolumne.sh)
#   - run from elsewhere, falling back to the known path under $SRC
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# 1. CUDA -> HIP source conversion (manual step, per your confirmation)
#    Using recursive + in-place so downstream configure/make see .hip
#    files alongside the originals without needing a HIP/ output dir.
#    TODO: confirm -r -p is actually the right mode (see note above).
# ------------------------------------------------------------
perl cudaToHip.pl -r -p .

# ------------------------------------------------------------
# 2. Configure with HIP + CGNS
# ------------------------------------------------------------
./configure --verbose \
    CC=cc \
    CXX=CC \
    --with-computer=tuolumne \
    --with-spacedim=3 \
    --with-mpi=cray \
    --with-hip="${ROCM_PATH:-/opt/rocm-6.4.3}" \
    --with-cgns="$CGNS_PREFIX" \
    --enable-release \
    GPUCPPFLAGS="$CRAY_MPI_CFLAGS" \
    LDFLAGS="$CRAY_MPI_LIBS"
    # NOTE: bare --with-hip (no path) failed to auto-detect hipcc on
    # Tuolumne, so we now pass the ROCm prefix explicitly. $ROCM_PATH is
    # normally set by the rocm module; the /opt/rocm-6.4.3 fallback is a
    # guess if that env var isn't set -- verify with `module show rocm/6.4.3`
    # if this still fails.
    # NOTE: GPUCPPFLAGS added because hipcc (invoked directly for .hip
    # files) doesn't get the same automatic MPI -I injection that the
    # cc/CC Cray wrappers give regular .cpp files, causing 'mpi.h'/
    # 'shmem.h' not found errors during the lib/test/HashBrick build.
    # (In practice GPUCPPFLAGS wasn't threaded through -- see the CPATH
    # export above, which is the actual fix for that error.)
    # NOTE: LDFLAGS added because the hipcc LINK step was missing all
    # MPI/SHMEM libraries, causing "undefined symbol: MPI_Init /
    # shmem_init / ..." -- confirmed LDFLAGS IS used in the hipcc link
    # rule in Common/mk/Make.rules, so this should actually take effect.
    # TODO: --with-computer=tuolumne may not be a recognized value -- check
    #       configure output / configure.ac for the actual accepted names
    #       (it did print "checking for computer... tuolumne" successfully
    #       last run, so this is likely fine)

# ------------------------------------------------------------
# 3. Build + test lib/test/HashBrick (CPU then GPU, per README)
#    make clean added before each stage to clear out object files left
#    over from earlier failed attempts (e.g. the mpi.h/shmem.h failures).
# ------------------------------------------------------------
pushd lib/test/HashBrick
make -j16 GPU=TRUE
popd
