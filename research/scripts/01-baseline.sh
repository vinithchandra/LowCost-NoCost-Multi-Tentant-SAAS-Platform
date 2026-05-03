#!/usr/bin/env bash
# Baseline snapshot: kubectl top + docker stats + cluster info.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"
mkdir -p "$DATA"

CSV="$DATA/baseline.csv"
TS=$(date -Iseconds)
[ -f "$CSV" ] || echo "timestamp,scope,name,cpu_m,mem_mi" > "$CSV"

echo "[baseline] node usage..."
kubectl top nodes --no-headers | awk -v ts="$TS" '{
  cpu=$2; gsub("m","",cpu);
  mem=$4; gsub("Mi","",mem);
  printf "%s,node,%s,%s,%s\n", ts, $1, cpu, mem
}' >> "$CSV"

echo "[baseline] pod usage..."
kubectl top pods -A --no-headers | awk -v ts="$TS" '{
  cpu=$3; gsub("m","",cpu);
  mem=$4; gsub("Mi","",mem);
  printf "%s,pod,%s/%s,%s,%s\n", ts, $1, $2, cpu, mem
}' >> "$CSV"

echo "[baseline] docker stats (one shot)..."
docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' \
  | grep devops-platform > "$DATA/docker-stats-$(date +%s).txt" || true

echo "[baseline] cluster summary..."
{
  echo "## $(date -Iseconds)"
  echo "### nodes"; kubectl get nodes -o wide
  echo "### pod count by namespace"; kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c
  echo "### k8s version"; kubectl version --short 2>/dev/null || kubectl version
  echo "### kind container"; docker ps --filter "name=devops-platform" --format '{{.Names}} {{.Status}} {{.Image}}'
} > "$DATA/cluster-info.md"

echo "[baseline] done. Rows in $CSV: $(wc -l < "$CSV")"
