#!/usr/bin/env bash
# Measure MTTR after manual config drift. We scale to (replicas-1), wait for
# ArgoCD self-heal to bring it back to the Git-declared replica count.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/mttr-drift.csv"
[ -f "$CSV" ] || echo "run,timestamp,action,t_drift,t_revert,mttr_seconds,replicas_desired,replicas_after_drift,replicas_after_heal" > "$CSV"

NS="${NS:-tenant-a}"
DEPLOY="${DEPLOY:-api-service}"
RUNS="${RUNS:-3}"

START_RUN=$(($(awk -F, 'END{print NR}' "$CSV")))
[ "$START_RUN" -lt 1 ] && START_RUN=1

for i in $(seq 1 "$RUNS"); do
  run=$((START_RUN + i - 1))
  echo "=== drift run $run / target $RUNS ==="
  desired=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}')
  drifted=$((desired - 1))
  [ "$drifted" -lt 1 ] && drifted=1

  # baseline ready
  kubectl wait --for=condition=Available --timeout=120s deploy/$DEPLOY -n $NS

  t_drift=$(date +%s.%N)
  kubectl scale deploy/$DEPLOY -n $NS --replicas=$drifted >/dev/null
  after_drift=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}')

  # wait until ArgoCD self-heals: spec.replicas back to desired AND status.readyReplicas == desired
  while :; do
    cur_spec=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    cur_ready=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "$cur_spec" = "$desired" ] && [ "${cur_ready:-0}" = "$desired" ]; then break; fi
    sleep 1
  done
  t_rev=$(date +%s.%N)
  after_heal=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}')

  mttr=$(awk -v a="$t_drift" -v b="$t_rev" 'BEGIN{printf "%.2f", b-a}')
  ts=$(date -Iseconds)
  echo "$run,$ts,scale-down-by-1,$t_drift,$t_rev,$mttr,$desired,$after_drift,$after_heal" >> "$CSV"
  echo "  desired=$desired drifted=$drifted healed=$after_heal mttr=${mttr}s"
  sleep 10
done

echo "[mttr-drift] done."
