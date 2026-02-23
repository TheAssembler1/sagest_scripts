#!/bin/bash

set -exu

module use /global/common/software/nersc/pe/modulefiles/latest
module load cray-pmi cray-openshmemx
module load cudatoolkit/12.9

CGNS_PREFIX=/pscratch/sd/n/nlewi26/src/CGNS/install

make clean
make GPU=true all
