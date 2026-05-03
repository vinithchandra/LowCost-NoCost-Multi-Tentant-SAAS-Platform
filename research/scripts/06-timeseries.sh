#!/usr/bin/env bash
# Time-series resource sampler. 30 s interval. Default 60 minutes total
# (30 min idle + 30 min with alert-simulator unsuspended). Tag column lets us
# split the data by phase later. Tolerant of transient kubectl/docker errors.
set -uo pipefail
trap 'echo "[ts] caught signal at $(date -Iseconds)"; exit 0' TERM INT
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/timeseries.csv"
DOCKER_CSV="$DATA/timeseries-docker.csv"
[ -f "$CSV" ] || echo "timestamp,phase,scope,name,cpu_m,mem_mi" > "$CSV"
[ -f "$DOCKER_CSV" ] || echo "timestamp,phase,name,cpu_pct,mem_usage" > "$DOCKER_CSV"

INTERVAL="${INTERVAL:-30}"
PHASE1_MIN="${PHASE1_MIN:-30}"   # idle
PHASE2_MIN="${PHASE2_MIN:-30}"   # under simulator load
TOTAL_MIN=$((PHASE1_MIN + PHASE2_MIN))

phase1_end=$(( $(date +%s) + PHASE1_MIN * 60 ))
phase2_end=$(( phase1_end + PHASE2_MIN * 60 ))

echo "[ts] starting; idle ${PHASE1_MIN} min, then load ${PHASE2_MIN} min."
echo "[ts] make sure alert-simulator is currently SUSPENDED."

sample() {
  local phase=$1
  local ts; ts=$(date -Iseconds)

  # node-level (tolerate failure)
  { kubectl top nodes --no-headers 2>/dev/null || true; } | awk -v ts="$ts" -v p="$phase" '{
    cpu=$2; gsub("m","",cpu);
    mem=$4; gsub("Mi","",mem);
    if (NF>=4) printf "%s,%s,node,%s,%s,%s\n", ts, p, $1, cpu, mem
  }' >> "$CSV" || true

  # pod-level
  { kubectl top pods -A --no-headers 2>/dev/null || true; } | awk -v ts="$ts" -v p="$phase" '{
    cpu=$3; gsub("m","",cpu);
    mem=$4; gsub("Mi","",mem);
    if (NF>=4) printf "%s,%s,pod,%s/%s,%s,%s\n", ts, p, $1, $2, cpu, mem
  }' >> "$CSV" || true

  # docker container
  { docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true; } \
    | grep devops-platform | awk -F'|' -v ts="$ts" -v p="$phase" '{
        cpu=$2; gsub("%","",cpu);
        printf "%s,%s,%s,%s,%s\n", ts, p, $1, cpu, $3
      }' >> "$DOCKER_CSV" || true
}

# PHASE 1: idle
echo "[ts] PHASE 1: idle until $(date -d "@$phase1_end" -Iseconds)"
while [ $(date +%s) -lt "$phase1_end" ]; do
  sample idle
  sleep "$INTERVAL"
done

# Transition: unsuspend simulator
echo "[ts] PHASE 2: unsuspending alert-simulator..."
kubectl patch cronjob alert-simulator -n platform-tools -p '{"spec":{"suspend":false}}' >/dev/null
echo "[ts] PHASE 2 sampling until $(date -d "@$phase2_end" -Iseconds)"
while [ $(date +%s) -lt "$phase2_end" ]; do
  sample load
  sleep "$INTERVAL"
done

# Suspend it back
echo "[ts] re-suspending alert-simulator..."
kubectl patch cronjob alert-simulator -n platform-tools -p '{"spec":{"suspend":true}}' >/dev/null

echo "[ts] done. ${TOTAL_MIN} minutes captured."
echo "[ts] rows in $CSV: $(wc -l < "$CSV")"
echo "[ts] rows in $DOCKER_CSV: $(wc -l < "$DOCKER_CSV")"
