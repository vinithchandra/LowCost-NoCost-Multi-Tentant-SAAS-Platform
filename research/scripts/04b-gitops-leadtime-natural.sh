#!/usr/bin/env bash
# Same as 04-gitops-leadtime.sh but WITHOUT forced argocd refresh/sync.
# Measures how long the natural (polling-driven) ArgoCD pipeline takes end-to-end.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/gitops-leadtime-natural.csv"
[ -f "$CSV" ] || echo "run,commit_sha,timestamp,from_replicas,to_replicas,t_push,t_pod_ready,leadtime_seconds_pod_ready" > "$CSV"

NS="${NS:-tenant-a}"
DEPLOY="${DEPLOY:-api-service}"
FILE="$REPO/k8s/tenants/${NS}/deployment.yaml"
RUNS="${RUNS:-3}"
START_RUN=$(($(awk -F, 'END{print NR}' "$CSV")))
[ "$START_RUN" -lt 1 ] && START_RUN=1

for i in $(seq 1 "$RUNS"); do
  run=$((START_RUN + i - 1))
  echo "=== natural gitops run $run / target $RUNS ==="
  current=$(grep -E "^  replicas: " "$FILE" | awk '{print $2}' | head -1)
  if [ "$current" = "3" ]; then new=2; else new=3; fi

  sed -i "s/^  replicas: $current$/  replicas: $new/" "$FILE"
  cd "$REPO"
  git add "$FILE" >/dev/null
  git commit -m "research: natural-leadtime run $run ($current -> $new)" >/dev/null
  t_push=$(date +%s.%N)
  git push --quiet >/dev/null
  sha=$(git rev-parse --short HEAD)
  echo "  pushed $sha replicas $current -> $new ; waiting for natural ArgoCD reconcile..."

  # NO forced refresh/sync. Wait for the deployment to naturally converge.
  while :; do
    spec=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    ready=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "$spec" = "$new" ] && [ "${ready:-0}" = "$new" ]; then break; fi
    sleep 1
  done
  t_ready=$(date +%s.%N)
  lt=$(awk -v a="$t_push" -v b="$t_ready" 'BEGIN{printf "%.2f", b-a}')
  ts=$(date -Iseconds)
  echo "$run,$sha,$ts,$current,$new,$t_push,$t_ready,$lt" >> "$CSV"
  echo "  natural leadtime ${lt}s"
  sleep 10
done
echo "[natural-leadtime] done."
