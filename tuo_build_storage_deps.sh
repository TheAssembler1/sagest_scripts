#!/usr/bin/env bash
set -exuo pipefail

module load cmake/3.29.2
module list

# SET THIS TO YOUR SRC DIR
SRC=/p/lustre5/lewis153/src
cd "$SRC"

# ============================================================
# HDF5 (release 2.2.0)
# ============================================================
git clone https://github.com/HDFGroup/hdf5.git hdf5-src
cd hdf5-src
git checkout 2.2.0

mkdir -p install build
cd build

CC=cc cmake .. \
  -DCMAKE_INSTALL_PREFIX="$SRC/hdf5-src/install" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DHDF5_ENABLE_PARALLEL=ON \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_BUILD_FORTRAN=OFF \
  -DHDF5_BUILD_TOOLS=ON \
  -DBUILD_TESTING=OFF

make -j 16
make install

export HDF5_DIR="$SRC/hdf5-src/install"

# ============================================================
# CGNS (v4.5.0)
# ============================================================
cd "$SRC"

git clone https://github.com/CGNS/CGNS.git CGNS-src
cd CGNS-src
git checkout v4.5.0

mkdir -p install build
cd build

CC=cc cmake .. \
  -DCMAKE_INSTALL_PREFIX="$SRC/CGNS-src/install" \
  -DCMAKE_PREFIX_PATH="$SRC/hdf5-src/install" \
  -DHDF5_NEED_MPI=ON \
  -DHDF5_IS_PARALLEL=ON \
  -DCGNS_ENABLE_HDF5=ON \
  -DCGNS_ENABLE_PARALLEL=ON \
  -DCGNS_BUILD_SHARED=ON \
  -DCGNS_ENABLE_FORTRAN=OFF

make -j 16
make install

echo "Done."
echo "HDF5 installed at:  $SRC/hdf5-src/install"
echo "CGNS installed at:  $SRC/CGNS-src/install
