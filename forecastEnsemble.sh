#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# forecastEnsemble.sh  (SERIAL)
#
# Push each ensemble member forward using Chord restart.
#
# For each member:
#   - set dt
#   - set final_time = nsteps * dt
#   - enable restart and set restart_file to earliest *.cgns in plot/member_XXX
#   - run: ./main_cpu ensemble/member_XXX/ShockTube.input
###############################################################################

ENSEMBLE_ROOT="ensemble"
PLOT_ROOT="plot"
EXE="./main_cpu"

DT="1.0e-5"
NSTEPS=10

usage() {
cat <<EOF
Usage:
  ./forecastEnsemble.sh
  ./forecastEnsemble.sh --dt 1.0e-5 --nsteps 10
  ./forecastEnsemble.sh --exe ./main_cpu

Options:
  --dt VAL      timestep size (default: 1.0e-5)
  --nsteps INT  number of steps to advance (default: 10)
  --exe PATH    Chord executable (default: ./main_cpu)

Notes:
  - final_time is set to (nsteps * dt)
  - restart_file is auto-detected as the earliest *.cgns in plot/member_XXX
EOF
}

# ----------------------------
# Parse args
# ----------------------------
while (( $# )); do
  case "$1" in
    --dt)      DT="$2"; shift 2 ;;
    --nsteps)  NSTEPS="$2"; shift 2 ;;
    --exe)     EXE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ----------------------------
# Compute final_time = nsteps * dt
# ----------------------------
FINAL_TIME="$(python3 - <<PY
dt = float("${DT}".replace("D","e").replace("d","e"))
n  = int("${NSTEPS}")
print(f"{n*dt:.16g}")
PY
)"

# ----------------------------
# Helpers
# ----------------------------
set_kv() {
  local key="$1"
  local val="$2"
  local file="$3"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
  else
    printf "\n%s = %s\n" "$key" "$val" >> "$file"
  fi
}

q() { printf "\"%s\"" "$1"; }

find_restart_file() {
  local plotdir="$1"
  local f
  f="$(find "$plotdir" -maxdepth 1 -type f -name "*.cgns" | sort | head -n 1 || true)"
  [[ -n "$f" ]] && echo "$f" || echo ""
}

# ----------------------------
# Find members
# ----------------------------
shopt -s nullglob
members=( "${ENSEMBLE_ROOT}"/member_* )
shopt -u nullglob

if (( ${#members[@]} == 0 )); then
  echo "No members found under: ${ENSEMBLE_ROOT}/member_*"
  echo "Did you run genEnsemble.sh first?"
  exit 1
fi

export OMP_NUM_THREADS=1

# ----------------------------
# SERIAL forecast
# ----------------------------
for memdir in "${members[@]}"; do
  mem="$(basename "$memdir")"
  infile="${memdir}/ShockTube.input"
  plotdir="${PLOT_ROOT}/${mem}"

  if [[ ! -f "$infile" ]]; then
    echo "Skipping ${mem}: missing ${infile}"
    continue
  fi

  if [[ ! -d "$plotdir" ]]; then
    echo "Skipping ${mem}: missing ${plotdir}"
    continue
  fi

  restart_file="$(find_restart_file "$plotdir")"
  if [[ -z "$restart_file" ]]; then
    echo "Skipping ${mem}: no *.cgns restart file found in ${plotdir}"
    continue
  fi

  # Patch time settings (dt + final_time only; number_time_steps untouched)
  set_kv "dt" "${DT}" "$infile"
  set_kv "final_time" "${FINAL_TIME}" "$infile"

  # Ensure plotting continues into the same member plot directory
  set_kv "plotting_prefix" "$(q "${plotdir}/")" "$infile"

  # Enable restart
  set_kv "use_restart" "true" "$infile"
  set_kv "restart_file" "$(q "${restart_file}")" "$infile"

  echo "------------------------------------------------------------"
  echo "Member:        ${mem}"
  echo "Input:         ${infile}"
  echo "Restart file:  ${restart_file}"
  echo "dt:            ${DT}"
  echo "nsteps:        ${NSTEPS}"
  echo "final_time:    ${FINAL_TIME}"
  echo "RUN:           ${EXE} ${infile}"
  echo "------------------------------------------------------------"

  # Run in foreground (serial)
  "$EXE" "$infile"
done

echo "Forecast ensemble complete."

