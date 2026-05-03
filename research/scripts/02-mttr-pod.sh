#!/usr/bin/env bash
# Measure MTTR after killing a tenant pod. Runs N times.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/mttr-pod.csv"
[ -f "$CSV" ] || echo "run,timestamp,victim_pod,t_kill,t_recovered,mttr_seconds" > "$CSV"

NS="${NS:-tenant-a}"
DEPLOY="${DEPLOY:-api-service}"
RUNS="${RUNS:-5}"

START_RUN=$(($(awk -F, 'END{print NR}' "$CSV")))   # next run number
[ "$START_RUN" -lt 1 ] && START_RUN=1

for i in $(seq 1 "$RUNS"); do
  run=$((START_RUN + i - 1))
  echo "=== run $run / target $RUNS ==="
  # ensure stable
  kubectl wait --for=condition=Available --timeout=120s deploy/$DEPLOY -n $NS

  # pick first pod
  victim=$(kubectl get pods -n $NS -l app=$DEPLOY -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
           || kubectl get pods -n $NS -o jsonpath='{.items[0].metadata.name}')

  desired=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}')

  t_kill=$(date +%s.%N)
  kubectl delete pod "$victim" -n $NS --grace-period=0 --force >/dev/null 2>&1

  # wait until deployment is fully Available (all replicas ready) again
  while :; do
    ready=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${ready:-0}" -ge "$desired" ] && break
    sleep 1
  done
  t_rec=$(date +%s.%N)

  mttr=$(awk -v a="$t_kill" -v b="$t_rec" 'BEGIN{printf "%.2f", b-a}')
  ts=$(date -Iseconds)
  echo "$run,$ts,$victim,$t_kill,$t_rec,$mttr" >> "$CSV"
  echo "  victim=$victim  mttr=${mttr}s"

  sleep 5  # cooldown
done

echo "[mttr-pod] done. $RUNS runs appended to $CSV"
