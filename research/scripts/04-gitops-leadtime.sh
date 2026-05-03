#!/usr/bin/env bash
# GitOps lead time: time from `git push` of a replica change until cluster reflects it.
# Strategy: edit replicas in a tenant deployment, commit+push, force-refresh ArgoCD, time until ready.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/gitops-leadtime.csv"
[ -f "$CSV" ] || echo "run,commit_sha,timestamp,from_replicas,to_replicas,t_push,t_argocd_synced,t_pod_ready,leadtime_seconds_argocd,leadtime_seconds_pod_ready" > "$CSV"

NS="${NS:-tenant-a}"
APP="${APP:-tenant-a}"
DEPLOY="${DEPLOY:-api-service}"
FILE="$REPO/k8s/tenants/${NS}/deployment.yaml"
RUNS="${RUNS:-3}"
START_RUN=$(($(awk -F, 'END{print NR}' "$CSV")))
[ "$START_RUN" -lt 1 ] && START_RUN=1

for i in $(seq 1 "$RUNS"); do
  run=$((START_RUN + i - 1))
  echo "=== gitops run $run / target $RUNS ==="

  current=$(grep -E "^  replicas: " "$FILE" | awk '{print $2}' | head -1)
  # toggle 2<->3 to keep numbers small
  if [ "$current" = "3" ]; then new=2; else new=3; fi

  sed -i "s/^  replicas: $current$/  replicas: $new/" "$FILE"
  cd "$REPO"
  git add "$FILE" >/dev/null
  git commit -m "research: gitops leadtime run $run ($current -> $new)" >/dev/null
  t_push=$(date +%s.%N)
  git push --quiet >/dev/null
  sha=$(git rev-parse --short HEAD)
  echo "  pushed $sha replicas $current -> $new"

  # Force ArgoCD to refresh & sync immediately so we measure pipeline speed, not poll lag.
  argocd app refresh "$APP" >/dev/null 2>&1 || true
  argocd app sync "$APP" --timeout 300 >/dev/null

  # Time until ArgoCD reports Synced to this revision
  while :; do
    rev=$(argocd app get "$APP" -o json 2>/dev/null | jq -r '.status.sync.revision[0:7]' 2>/dev/null || echo "")
    [ "$rev" = "$sha" ] && break
    sleep 1
  done
  t_synced=$(date +%s.%N)

  # Time until deployment is fully ready at the new replica count
  while :; do
    spec=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    ready=$(kubectl get deploy $DEPLOY -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "$spec" = "$new" ] && [ "${ready:-0}" = "$new" ]; then break; fi
    sleep 1
  done
  t_ready=$(date +%s.%N)

  lt_sync=$(awk -v a="$t_push" -v b="$t_synced" 'BEGIN{printf "%.2f", b-a}')
  lt_ready=$(awk -v a="$t_push" -v b="$t_ready" 'BEGIN{printf "%.2f", b-a}')
  ts=$(date -Iseconds)
  echo "$run,$sha,$ts,$current,$new,$t_push,$t_synced,$t_ready,$lt_sync,$lt_ready" >> "$CSV"
  echo "  argocd-sync ${lt_sync}s, pod-ready ${lt_ready}s"
  sleep 5
done
echo "[gitops-leadtime] done. (NOTE: argocd app sync was forced; this measures argo+k8s, not poll latency.)"
