#!/usr/bin/env bash
set -xeuo pipefail

###############################################################################
# genEnsemble.sh
# Generates N perturbed input files. Does NOT run main_cpu.
# Usage: ./genEnsemble.sh --N 8 --seed 42
###############################################################################

N=1

usage() {
cat <<EOF
Usage:
  ./genEnsemble.sh --N 8 --seed 42

Options:
  --N INT     number of ensemble members to generate (default: 1)
  --seed INT  random seed (default: 1)
EOF
}
SEED=1
BASE_INPUT="inputFiles/ShockTube.input"
ENSEMBLE_ROOT="ensemble"
PLOT_ROOT="plot"

LOC_SIGMA=0.05
P_SIG=0.15
RHO_SIG=0.15
GAMMA_SIG=0.1

for ((i=1;i<=$#;i++)); do
  case "${!i}" in
    --N) ((i++)); N="${!i}" ;;
    -h|--help) usage; exit 0 ;;
    --seed) ((i++)); SEED="${!i}" ;;
  esac
done

mkdir -p "$ENSEMBLE_ROOT" "$PLOT_ROOT"

get_val() {
  awk -v k="$1" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      sub("^[^=]*=","",$0); gsub(/^[ \t]+|[ \t]+$/,""); print; exit
    }' "$BASE_INPUT"
}

BASE_LOC=$(get_val "SHOCK.location")
BASE_PLOW=$(get_val "SHOCK.pressureLow")
BASE_PHIGH=$(get_val "SHOCK.pressureHigh")
BASE_RLOW=$(get_val "SHOCK.densityLow")
BASE_RHIGH=$(get_val "SHOCK.densityHigh")
BASE_GAMMA=$(get_val "GP.gamma")

mapfile -t PARAMS < <(python3 - <<PY
import random, math
random.seed(int("${SEED}"))
for _ in range(int("${N}")):
    z = lambda: random.gauss(0,1)
    loc = max(0.0, min(1.0, float("${BASE_LOC}") + float("${LOC_SIGMA}")*z()))
    pL  = float("${BASE_PLOW}")  * math.exp(float("${P_SIG}")*z())
    pH  = float("${BASE_PHIGH}") * math.exp(float("${P_SIG}")*z())
    rL  = float("${BASE_RLOW}")  * math.exp(float("${RHO_SIG}")*z())
    rH  = float("${BASE_RHIGH}") * math.exp(float("${RHO_SIG}")*z())
    gam = float("${BASE_GAMMA}") * math.exp(float("${GAMMA_SIG}")*z())
    print(f"{loc} {pL} {pH} {rL} {rH} {gam}")
PY
)

patch() {
  sed -i -E "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "$3"
}

for ((m=1; m<=N; m++)); do
  mem=$(printf "%03d" $m)
  memdir="${ENSEMBLE_ROOT}/member_${mem}"
  mkdir -p "$memdir"

  infile="${memdir}/ShockTube.input"
  cp "$BASE_INPUT" "$infile"

  read loc pL pH rL rH gam <<< "${PARAMS[$((m-1))]}"

  patch "SHOCK.location"    "$loc" "$infile"
  patch "SHOCK.pressureLow" "$pL"  "$infile"
  patch "SHOCK.pressureHigh" "$pH" "$infile"
  patch "SHOCK.densityLow"  "$rL"  "$infile"
  patch "SHOCK.densityHigh" "$rH"  "$infile"
  patch "GP.gamma"          "$gam" "$infile"

  echo "[GEN] Created ensemble/member_${mem}/ShockTube.input"
done

echo "[GEN] Done. Generated $N members."
