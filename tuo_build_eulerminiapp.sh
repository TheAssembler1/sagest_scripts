#!/usr/bin/env bash
set -exuo pipefail

# ============================================================
# Build script: euler-miniapp -- Tuolumne (LLNL)
# ============================================================
# Sources for this script:
#   - euler-miniapp/GNUmakefile (pasted directly) -- HASHBRICK_HOME now
#     points at the built /p/lustre5/lewis153/src/hashbrick checkout
#     (you fixed this path).
#   - build_hashbrick_tuolumne.sh (this session) -- euler-miniapp links
#     against libHashBrick_gpu.a, so it needs the same modules and
#     MPI/SHMEM include+link fixes HashBrick itself needed.
#   - Real build attempt in this session: building directly from the
#     euler-miniapp root failed with "Parameters.hpp file not found" --
#     you confirmed (recalling Andy) the actual workflow is: hippify
#     euler-miniapp's sources into a HIP/ subdirectory, copy GNUmakefile
#     into HIP/, and build FROM INSIDE HIP/. Your existing (pre-script)
#     HIP/ directory listing showed: .hip files (EulerOperator.hip,
#     main.hip), unchanged .hpp/.cpp files, GNUmakefile, and a prior
#     main_gpu binary -- consistent with cudaToHip.pl's DEFAULT mode
#     (no -r, no -p), which writes converted/copied files into a HIP/
#     subdirectory rather than converting in-place (that in-place mode
#     was used for hashbrick itself, NOT here).
#
# Scope: builds euler-miniapp only, assuming hashbrick has already been
# built successfully (see build_hashbrick_tuolumne.sh). Does not rebuild
# HashBrick.
#
# CONFIRMED from the HashBrick build in this session (real runs on
# Tuolumne, carried over as very likely to apply here too -- same
# toolchain/library):
#   - rocm/6.4.3, cray-dsmml, cray-pmi, cray-openshmemx/11.8.0 modules
#     needed, in that load order.
#   - hipcc doesn't get Cray's automatic MPI -I injection -- fixed via
#     CPATH export.
#   - hipcc's link step doesn't get MPI/SHMEM libraries automatically --
#     fixed via LDFLAGS from `cc --cray-print-opts=libs`, confirmed
#     threaded through Common/mk/Make.rules (which euler-miniapp's
#     GNUmakefile includes via Make.example).
#
# STILL UNCONFIRMED (flagged inline with TODO):
#   1. Whether cudaToHip.pl's DEFAULT (non -r, non -p) mode, run once
#      on the euler-miniapp root, is exactly right -- inferred from the
#      pre-existing HIP/ directory's contents, not verified against a
#      fresh run in this session. (UPDATE: a real run in this session
#      DID reproduce the same HIP/ layout, so this is now more likely
#      correct, though still not independently verified beyond matching
#      appearance.)
#   2. RESOLVED: CPPFLAGS/LDFLAGS must be exported as environment
#      variables, NOT passed as `make VAR=...` command-line arguments --
#      confirmed by a real failure (see below).
#   3. GLOBAL_ARENA=TRUE per Andy's Tuolumne shared-memory workaround --
#      confirmed as a real GNUmakefile variable, not yet confirmed
#      necessary/sufficient when building from HIP/.
#   4. Whether USEHIP=TRUE (added after diagnosing the CPPFLAGS lock
#      issue) is sufficient on its own, or whether GPU=TRUE is also still
#      required alongside it -- both are passed below to be safe, but
#      not yet confirmed which one(s) are actually necessary.
#
# KEY FINDING from a real failure in this session: passing
# `make CPPFLAGS=... LDFLAGS=...` on the command line caused
# "Parameters.hpp/OutputStream.hpp/Error.hpp file not found" even though
# Make.example unconditionally appends `-I$(_lib_dirs) -I$(base_dir)` to
# CPPFLAGS. Root cause: GNU Make gives command-line variable assignments
# top priority, which silently blocks EVERY `+=` to that variable inside
# included makefiles (not just HIP-specific lines) unless the makefile
# uses the `override` directive. Fixed by exporting CPPFLAGS/LDFLAGS as
# environment variables instead, which Make.example's own `+=` logic can
# still build on top of.
# ============================================================

# SET THIS
SRC=/p/lustre5/lewis153/src
HASHBRICK_DIR="$SRC/hashbrick"
EULER_DIR="$SRC/euler-miniapp"

# ------------------------------------------------------------
# Modules -- same set as the HashBrick build in this session
# ------------------------------------------------------------
module load cmake/3.29.2
module load rocm/6.4.3          # default (D) module per `module avail rocm` on Tuolumne
module load cray-dsmml          # required dependency of cray-openshmemx (Lmod error otherwise)
module load cray-pmi            # provides libpmi/libpmi2 -- fixes "ld.lld: error: unable to find library -lpmi[2]"
module load cray-openshmemx/11.8.0   # default (D) module; provides mpi.h/shmem.h
module list

# Sanity check: hipcc must be reachable once the module is loaded.
if ! command -v hipcc >/dev/null 2>&1; then
    echo "ERROR: hipcc still not on PATH after 'module load rocm/6.4.3'." >&2
    echo "       Check 'module show rocm/6.4.3' for where it installs hipcc," >&2
    echo "       and set ROCM_PATH manually below if needed." >&2
    exit 1
fi
echo "hipcc found at: $(command -v hipcc)"

CRAY_MPI_CFLAGS="$(cc --cray-print-opts=cflags)"
echo "Cray MPI/libsci include flags: $CRAY_MPI_CFLAGS"

CRAY_MPI_LIBS="$(cc --cray-print-opts=libs)"
echo "Cray MPI/SHMEM link flags: $CRAY_MPI_LIBS"

# WORKAROUND (carried over from the HashBrick build): hipcc doesn't pick
# up MPI/SHMEM headers automatically -- export CPATH so Clang (which
# hipcc wraps) finds them for every compile regardless of what the
# Makefile passes.
CRAY_MPI_INCLUDE_DIRS="$(echo "$CRAY_MPI_CFLAGS" | tr ' ' '\n' | sed -n 's/^-I//p' | paste -sd: -)"
export CPATH="${CRAY_MPI_INCLUDE_DIRS}${CPATH:+:$CPATH}"
echo "CPATH set to: $CPATH"

# ------------------------------------------------------------
# Locate euler-miniapp. Works whether this script is run from inside
# the repo itself or from elsewhere, falling back to the known path.
# ------------------------------------------------------------
if [ -f "./GNUmakefile" ] && [ -f "./main.cu" ]; then
    EULER_DIR="$(pwd)"
elif [ -f "$SRC/euler-miniapp/GNUmakefile" ]; then
    EULER_DIR="$SRC/euler-miniapp"
else
    echo "ERROR: could not find euler-miniapp's GNUmakefile + main.cu, either" >&2
    echo "       in the current directory or at $SRC/euler-miniapp." >&2
    echo "       Run this script from inside euler-miniapp, or fix SRC above." >&2
    exit 1
fi

cd "$EULER_DIR"
echo "Building euler-miniapp in: $EULER_DIR"

# ------------------------------------------------------------
# Sanity check: HASHBRICK_HOME in GNUmakefile must resolve to a real,
# already-built HashBrick checkout.
# ------------------------------------------------------------
HASHBRICK_HOME_LINE="$(grep '^HASHBRICK_HOME' GNUmakefile || true)"
echo "GNUmakefile HASHBRICK_HOME line: $HASHBRICK_HOME_LINE"
if [ ! -f "$HASHBRICK_DIR/lib/libHashBrick_gpu.a" ]; then
    echo "WARNING: could not find a built libHashBrick_gpu.a at $HASHBRICK_DIR." >&2
    echo "         Build HashBrick first (see build_hashbrick_tuolumne.sh)." >&2
fi

# ------------------------------------------------------------
# 1. CUDA -> HIP conversion (hippify), DEFAULT mode: writes into a HIP/
#    subdirectory rather than converting in-place. Uses hashbrick's own
#    cudaToHip.pl since euler-miniapp doesn't have its own copy.
# ------------------------------------------------------------
perl "$HASHBRICK_DIR/cudaToHip.pl" .

# ------------------------------------------------------------
# 1b. Post-hippify fixups for CUDA symbols missing from cudaToHip.pl's
#     mapping table. Applied here (not by editing cudaToHip.pl itself,
#     which is shared with the hashbrick repo) since default hippify
#     mode regenerates HIP/ from scratch every run -- a manual patch to
#     a file inside HIP/ would be silently overwritten next time.
#     TODO: add more symbols here as they're discovered; consider
#     upstreaming missing ones into cudaToHip.pl's %CUDA_TO_HIP_SIMPLE
#     table if this list grows.
# ------------------------------------------------------------
if [ -d HIP ]; then
    # Known-good specific fixups first (documented, easy to audit).
    find HIP -name '*.hip' -exec sed -i \
        -e 's/\bcudaEventBlockingSync\b/hipEventBlockingSync/g' \
        -e 's/\bcudaEventCreateWithFlags\b/hipEventCreateWithFlags/g' \
        {} +

    # GENERAL FALLBACK: any remaining CamelCase identifier starting with
    # "cuda" (e.g. cudaFoo, cudaBarBaz) gets its prefix swapped to "hip".
    # This mirrors HIP's standard 1:1 CUDA runtime API renaming convention
    # and catches symbols cudaToHip.pl's mapping table is missing (two
    # found so far: cudaEventBlockingSync, cudaEventCreateWithFlags --
    # both direct 1:1 renames per the compiler's own "did you mean"
    # suggestion). TODO: this is a heuristic, not a verified mapping --
    # if a compile error shows a *different* HIP name than a plain
    # cuda->hip prefix swap (unlike the two found so far), add it as a
    # specific fixup above instead and remove reliance on the fallback
    # for that symbol.
    find HIP -name '*.hip' -exec sed -i -E 's/\bcuda([A-Z][A-Za-z0-9_]*)\b/hip\1/g' {} +
fi

# ------------------------------------------------------------
# 2. Copy GNUmakefile into HIP/ and build FROM INSIDE HIP/ -- per your
#    recollection of Andy's instructions. cudaToHip.pl's default mode
#    does not copy GNUmakefile itself (it's not a recognized source
#    extension), so this step is required every time after hippifying.
# ------------------------------------------------------------
cp GNUmakefile HIP/
cd HIP
echo "Building from: $(pwd)"

# ------------------------------------------------------------
# 3. Reset build state, then build GPU target.
#
# IMPORTANT: CPPFLAGS/LDFLAGS are exported as ENVIRONMENT variables here,
# NOT passed as `make VAR=...` command-line arguments. GNU Make gives
# command-line variable assignments top priority, which silently blocks
# EVERY `+=` to that variable inside the included makefiles -- confirmed
# by a real failure where `make CPPFLAGS= ...` (empty, since
# CRAY_MPI_CFLAGS was empty that run) locked CPPFLAGS empty and blocked
# even the unconditional `-I$(_lib_dirs) -I$(base_dir)` line in
# Make.example, causing "Parameters.hpp/OutputStream.hpp/Error.hpp file
# not found" even though those -I flags should always be added.
# Exporting as env vars instead lets Make.example's own `+=` logic apply
# on top, same as make normally expects.
#
# USEHIP=TRUE is passed on the command line deliberately (safe here --
# it's a plain conditional flag consulted by ifeq, not a variable that
# gets appended to, so it isn't subject to the override-lock problem
# above). GLOBAL_ARENA=TRUE per Andy's Tuolumne workaround.
# ------------------------------------------------------------
export CPPFLAGS="$CRAY_MPI_CFLAGS"
export LDFLAGS="$CRAY_MPI_LIBS"

make clean
make -j16 GPU=TRUE USEHIP=TRUE GLOBAL_ARENA=TRUE

echo "euler-miniapp build complete (built from HIP/)."
