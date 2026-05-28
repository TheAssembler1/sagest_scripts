#!/usr/bin/env bash
set -xeuo pipefail

ENSEMBLE_ROOT="ensemble"
PLOT_ROOT="plot"
DT="1.0e-5"
NSTEPS=1
RANKS_PER_MEMBER=32
MEMBERS_PER_NODE=1

usage() {
cat <<USAGE
Usage:
  ./forecastEnsemble.sh
  ./forecastEnsemble.sh --dt 1.0e-5 --nsteps 10 --ranks-per-member 1 --members-per-node 1

Options:
  --dt VAL                timestep size (default: 1.0e-5)
  --nsteps INT            number of steps to advance (default: 1)
  --ranks-per-member INT  MPI ranks per member (default: 1)
  --members-per-node INT  members per node (default: 1)
USAGE
}

while (( $# )); do
  case "$1" in
    --dt)               DT="$2";               shift 2 ;;
    --nsteps)           NSTEPS="$2";           shift 2 ;;
    --ranks-per-member) RANKS_PER_MEMBER="$2"; shift 2 ;;
    --members-per-node) MEMBERS_PER_NODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

FINAL_TIME="$(python3 - <<PY
dt = float("${DT}".replace("D","e").replace("d","e"))
n  = int("${NSTEPS}")
print(f"{n*dt:.16g}")
PY
)"

set_kv() {
  local key="$1" val="$2" file="$3"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
  else
    printf "\n%s = %s\n" "$key" "$val" >> "$file"
  fi
}

q() { printf "\"%s\"" "$1"; }

shopt -s nullglob
members=( "${ENSEMBLE_ROOT}"/member_* )
shopt -u nullglob

if (( ${#members[@]} == 0 )); then
  echo "No members found under: ${ENSEMBLE_ROOT}/member_*"
  echo "Did you run genEnsemble.sh first?"
  exit 1
fi

mapfile -t NODES < <(scontrol show hostnames "$SLURM_NODELIST")
echo "Nodes: ${NODES[*]}"

export OMP_NUM_THREADS=1

member_count=0

for memdir in "${members[@]}"; do
  mem="$(basename "$memdir")"
  infile="${memdir}/ShockTube.input"
  plotdir="${PLOT_ROOT}/${mem}"

  if [[ ! -f "$infile" ]]; then
    echo "Skipping ${mem}: missing ${infile}"
    continue
  fi

  _node_idx=$(( member_count / MEMBERS_PER_NODE ))
  if (( _node_idx >= ${#NODES[@]} )); then
    echo "Skipping ${mem}: no node available (only ${#NODES[@]} nodes allocated)"
    member_count=$(( member_count + 1 ))
    continue
  fi

  mkdir -p "$plotdir"
  lfs setstripe -c 256 -S 8m "$plotdir"

  set_kv "dt"              "${DT}"              "$infile"
  set_kv "number_time_steps" "${NSTEPS}"          "$infile"
  set_kv "plotting_prefix" "$(q "${plotdir}/")" "$infile"
  set_kv "use_restart"     "false"              "$infile"

  TARGET_NODE="${NODES[${_node_idx}]}"

  echo "------------------------------------------------------------"
  echo "Member:  ${mem}  ->  node ${TARGET_NODE}"
  echo "dt:      ${DT}   nsteps: ${NSTEPS}   final_time: ${FINAL_TIME}"
  echo "------------------------------------------------------------"

  SHMEM_SYMMETRIC_SIZE=32G \
    NVSHMEM_DISABLE_CUDA_VMM=1 \
    srun --mpi=cray_shasta --gpus-per-task=1 \
         --gpu-bind=map_gpu:0,1,2,3 \
         -n "${RANKS_PER_MEMBER}" \
         --ntasks-per-node="${RANKS_PER_MEMBER}" \
         --nodelist="${TARGET_NODE}" \
         --exact \
         ./main_gpu "$infile" &

  member_count=$(( member_count + 1 ))
done

wait
echo "Forecast ensemble complete."
