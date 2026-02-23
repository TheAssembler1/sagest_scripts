#!/bin/bash

set -exu

module use /global/common/software/nersc/pe/modulefiles/latest
module load cray-pmi cray-openshmemx
module load cudatoolkit/12.9

CGNS_PREFIX=/pscratch/sd/n/nlewi26/src/CGNS/install

./configure --verbose \
    CC=cc \
    CXX=CC \
    --with-computer=perlmutter \
    --with-spacedim=3 \
    --with-mpi=cray \
    --with-cudatk=$CUDATOOLKIT_HOME \
    --with-nvshmem=$NVSHMEM_HOME \
    --with-cgns=$CGNS_PREFIX \
    --enable-release

pushd lib
make clean
make GPU=TRUE all
pushd test/HashBrick
make GPU=TRUE all
popd
popd

