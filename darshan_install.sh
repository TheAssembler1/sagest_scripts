nlewi26@login14:~$ cat darshan_install.sh
#!/usr/bin/env bash
#
# Build a personal Darshan on Perlmutter that writes logs to a user-chosen
# path (via DARSHAN_LOGFILE or PWD) instead of the unwritable system
# /pscratch/darshanlogs directory.
#
# Produces:
#   $DARSHAN_PREFIX/lib/libdarshan.so   <- preload this on compute nodes
#   $DARSHAN_PREFIX/bin/darshan-parser  <- parse logs on the login node
#
# Usage:
#   ./build_darshan_perlmutter.sh
# then follow the "HOW TO USE" notes printed at the end.

set -xeuo pipefail

#----------------------------------------------------------------------------
# Config -- adjust if you want a different version or install location.
#----------------------------------------------------------------------------
DARSHAN_VERSION="3.4.7"
SRC_ROOT="$HOME/src/darshan-build"
DARSHAN_PREFIX="$HOME/opt/darshan-${DARSHAN_VERSION}"
TARBALL="darshan-${DARSHAN_VERSION}.tar.gz"
# GitHub release tarball (the old ftp.mcs.anl.gov mirror is retired):
# https://web.cels.anl.gov/projects/darshan/releases/darshan-3.4.7.tar.gz
URL="https://web.cels.anl.gov/projects/darshan/releases/${TARBALL}"

#----------------------------------------------------------------------------
# Environment: Darshan must be built with the GNU programming environment so
# the resulting library interoperates with the widest range of compilers.
# On Perlmutter, unload the system darshan module first to avoid conflicts.
#----------------------------------------------------------------------------
module unload darshan 2>/dev/null || true
# Swap to PrgEnv-gnu (whatever PrgEnv is currently loaded).
current_prgenv="$(module -t list 2>&1 | grep -i 'PrgEnv' | head -1 || true)"
if [ -n "${current_prgenv}" ]; then
  module swap "${current_prgenv}" PrgEnv-gnu
else
  module load PrgEnv-gnu
fi
module list

#----------------------------------------------------------------------------
# Fetch + unpack
#----------------------------------------------------------------------------
mkdir -p "${SRC_ROOT}"
cd "${SRC_ROOT}"
if [ ! -f "${TARBALL}" ]; then
  wget -O "${TARBALL}" "${URL}"
fi
rm -rf "darshan-${DARSHAN_VERSION}"
tar -xzf "${TARBALL}"
cd "darshan-${DARSHAN_VERSION}"

# 3.4.x release tarballs ship without generated autotools configure scripts;
# bootstrap them. Requires autoconf/automake/libtool in PATH.
if [ ! -x darshan-runtime/configure ]; then
  ./prepare.sh
fi

#----------------------------------------------------------------------------
# 1) darshan-runtime  (compute-node library; build with the Cray cc wrapper
#    so MPI is linked the same way as your application).
#
#    --with-log-path-by-env=DARSHAN_LOGFILE,PWD
#        At runtime Darshan scans these env vars (in order) for where to drop
#        the log.  DARSHAN_LOGFILE lets you name an exact file; PWD is the
#        fallback directory.  This is what the system build was missing.
#    --with-jobid-env=SLURM_JOBID   embed the Slurm job id in the log name
#    --enable-mmap-logs             safer partial logs if a job aborts
#    --disable-cuserid              avoid cuserid() (can hang on some systems)
#----------------------------------------------------------------------------
cd darshan-runtime
CC=cc ./configure \
  --prefix="${DARSHAN_PREFIX}" \
  --with-log-path-by-env=DARSHAN_LOGFILE,PWD \
  --with-jobid-env=SLURM_JOBID \
  --enable-mmap-logs \
  --disable-cuserid \
  --with-mem-align=8
make -j8
make install
cd ..

#----------------------------------------------------------------------------
# 2) darshan-util  (login-node parser; plain gcc, no MPI needed)
#----------------------------------------------------------------------------
cd darshan-util
CC=gcc ./configure --prefix="${DARSHAN_PREFIX}"
make -j8
make install
cd ..

set +x
cat <<EOF

============================================================================
Darshan ${DARSHAN_VERSION} installed to: ${DARSHAN_PREFIX}
============================================================================

HOW TO USE  (in your job script, replacing the system darshan paths)

  # Point the preload at YOUR libdarshan, keep the Cray GTL lib second:
  export DARSHAN_LIB=${DARSHAN_PREFIX}/lib/libdarshan.so
  export GTL_LIB=/opt/cray/pe/lib64/libmpi_gtl_cuda.so.0

  # Name the exact log file you want (honored because of
  # --with-log-path-by-env=DARSHAN_LOGFILE,PWD):
  export DARSHAN_LOGFILE=\$PWD/euler_\${SLURM_JOBID:-test}.darshan

  # Optional: enable HDF5 module + DXT fine-grained traces
  export DXT_ENABLE_IO_TRACE=1

  srun ... \\
    --export=ALL,DARSHAN_LOGFILE=\$DARSHAN_LOGFILE,LD_PRELOAD=\$DARSHAN_LIB:\$GTL_LIB \\
    ./main_gpu "\$infile"

PARSE THE LOG (login node):

  ${DARSHAN_PREFIX}/bin/darshan-parser \$PWD/euler_*.darshan | less
  # human summary fields are near the top; per-file counters below.

NOTE ON HDF5: to capture CGNS/HDF5-level records (not just POSIX/MPI-IO),
your darshan.conf should enable the HDF5 module, e.g.:
  MOD_ENABLE POSIX,MPI-IO,H5F,H5D
(only works if this build detected HDF5 at configure time; if you need it and
it is missing, re-run darshan-runtime configure with --enable-hdf5-mod and
--with-hdf5=<path to your parallel HDF5 install>.)
============================================================================
EOF
nlewi26@login14:~$
