#!/usr/bin/env bash
# Alert pipeline latency: time from POSTing the n8n webhook to its response.
# Note: this is the curl->respond round-trip (n8n receives + IF + HTTP to webhook.site + Respond).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/alert-latency.csv"
[ -f "$CSV" ] || echo "run,timestamp,severity,t_curl_start,t_curl_end,latency_ms,http_code" > "$CSV"

URL="${URL:-http://localhost:30002/webhook/alert}"
RUNS="${RUNS:-10}"
START_RUN=$(($(awk -F, 'END{print NR}' "$CSV")))
[ "$START_RUN" -lt 1 ] && START_RUN=1

for i in $(seq 1 "$RUNS"); do
  run=$((START_RUN + i - 1))
  case $((i % 3)) in
    0) sev=info; alert=DeploymentRolled; sum="New revision deployed" ;;
    1) sev=critical; alert=HighErrorRate; sum="Error rate exceeded 1%" ;;
    *) sev=warning; alert=PodMemoryHigh; sum="Memory above 80%" ;;
  esac
  payload=$(cat <<EOF
{"alertname":"$alert","severity":"$sev","namespace":"tenant-a","summary":"$sum"}
EOF
)
  t0=$(date +%s.%N)
  http=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$URL")
  t1=$(date +%s.%N)
  ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", (b-a)*1000}')
  ts=$(date -Iseconds)
  echo "$run,$ts,$sev,$t0,$t1,$ms,$http" >> "$CSV"
  echo "  run $run sev=$sev http=$http latency=${ms}ms"
  sleep 1
done
echo "[alert-latency] done."
