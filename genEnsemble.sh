#!/usr/bin/env bash
set -exuo pipefail

###############################################################################
# genEnsemble.sh
#
# Workflow per member:
#   mkdir ensemble/member_XXX
#   mkdir plot/member_XXX
#   generate ensemble/member_XXX/ShockTube.input
#   RUN: ./main_cpu ensemble/member_XXX/ShockTube.input
###############################################################################

# ----------------------------
# Defaults
# ----------------------------
N=1
JOBS=1
EXE="./main_cpu"
BASE_INPUT="inputFiles/ShockTube.input"

ENSEMBLE_ROOT="ensemble"
PLOT_ROOT="plot"

SEED=1

# perturbation magnitudes
LOC_SIGMA=0.05       # absolute
P_SIG=0.15           # 15% pressure
RHO_SIG=0.15         # 15% density
GAMMA_SIG=0.1        # 10% gamma

usage() {
cat <<EOF
Usage:
  ./genEnsemble.sh --N=20 -j 8

Options:
  --N INT            number of ensemble members
  -j INT             parallel jobs
  --seed INT         RNG seed
EOF
}

# ----------------------------
# Parse args
# ----------------------------
for ((i=1;i<=$#;i++)); do
  case "${!i}" in
    --N) ((i++)); N="${!i}" ;;
    -j)  ((i++)); JOBS="${!i}" ;;
    --seed) ((i++)); SEED="${!i}" ;;
    -h|--help) usage; exit 0 ;;
  esac
done

mkdir -p "$ENSEMBLE_ROOT" "$PLOT_ROOT"

# ----------------------------
# Extract baseline values
# ----------------------------
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

# ----------------------------
# Generate perturbations
# ----------------------------
echo "SEED=$SEED"
echo "N=$N"
echo "BASE_LOC=$BASE_LOC"
echo "LOC_SIGMA=$LOC_SIGMA"
echo "BASE_PLOW=$BASE_PLOW"
echo "BASE_PHIGH=$BASE_PHIGH"
echo "BASE_RLOW=$BASE_RLOW"
echo "BASE_RHIGH=$BASE_RHIGH"
echo "BASE_GAMMA=$BASE_GAMMA"
echo "P_SIG=$P_SIG"
echo "RHO_SIG=$RHO_SIG"
echo "GAMMA_SIG=$GAMMA_SIG"
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

# ----------------------------
# Helper to patch inputs
# ----------------------------
patch() {
  sed -i -E "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2|" "$3"
}

RUN_CMDS=()

# ----------------------------
# Create members + commands
# ----------------------------
for ((m=1; m<=N; m++)); do
  mem=$(printf "%03d" $m)
  memdir="${ENSEMBLE_ROOT}/member_${mem}"
  plotdir="${PLOT_ROOT}/member_${mem}"
  mkdir -p "$memdir" "$plotdir"

  infile="${memdir}/ShockTube.input"
  cp "$BASE_INPUT" "$infile"

  read loc pL pH rL rH gam <<< "${PARAMS[$((m-1))]}"

  patch "final_time" "0" "$infile"
  patch "plotting_prefix" "\"${plotdir}/\"" "$infile"
  patch "SHOCK.location" "$loc" "$infile"
  patch "SHOCK.pressureLow" "$pL" "$infile"
  patch "SHOCK.pressureHigh" "$pH" "$infile"
  patch "SHOCK.densityLow" "$rL" "$infile"
  patch "SHOCK.densityHigh" "$rH" "$infile"
  patch "GP.gamma" "$gam" "$infile"

  RUN_CMDS+=("$EXE $infile")
done

# -----------
# Run Chord
# -----------

export OMP_NUM_THREADS=1

for ((m=1; m<=N; m++)); do
  mem=$(printf "%03d" $m)
  infile="${ENSEMBLE_ROOT}/member_${mem}/ShockTube.input"

  echo "Running: $EXE $infile"
  "$EXE" "$infile"
done

echo "Ensemble complete."

