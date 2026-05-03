#!/usr/bin/env bash
# 04c-gitops-leadtime-webhook.sh
# Measures end-to-end GitOps lead time with GitHub webhook driving ArgoCD.
# Differs from 04b (natural polling) by NOT forcing an argocd refresh/sync —
# all sync activity is triggered purely by the webhook GitHub sends on push.
#
# Output: research/data/gitops-leadtime-webhook.csv
#   columns: run,replicas_target,t_push,t_synced,t_ready,leadtime_sync_s,leadtime_ready_s

set -uo pipefail
trap 'echo "interrupted"; exit 130' INT TERM

RUNS="${RUNS:-5}"
NS="${NS:-tenant-a}"
APP="${APP:-tenant-a}"                    # argocd Application name
DEPLOY="${DEPLOY:-api-service}"
MANIFEST="k8s/tenants/tenant-a/deployment.yaml"
OUT="research/data/gitops-leadtime-webhook.csv"
mkdir -p "$(dirname "$OUT")"

if [ ! -f "$OUT" ] || [ ! -s "$OUT" ]; then
  echo "run,replicas_target,t_push,t_synced,t_ready,leadtime_sync_s,leadtime_ready_s" > "$OUT"
fi

# Pre-check: ensure argocd app exists and repo is clean
argocd app get "$APP" >/dev/null 2>&1 || { echo "ERROR: argocd app $APP not found; login with argocd login first"; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is dirty. commit or stash first."; exit 1
fi

current_replicas() {
  grep -E "^\s*replicas:\s*[0-9]+" "$MANIFEST" | head -1 | awk '{print $2}'
}

wait_for_sync_rev() {
  local target_rev="$1" deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local synced_rev
    synced_rev=$(argocd app get "$APP" -o json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',{}).get('sync',{}).get('revision',''))")
    if [ "$synced_rev" = "$target_rev" ]; then
      echo "$(date +%s)"; return 0
    fi
    sleep 1
  done
  echo "0"; return 1
}

wait_for_ready() {
  local target="$1" deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ready
    ready=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    ready=${ready:-0}
    if [ "$ready" = "$target" ]; then
      echo "$(date +%s)"; return 0
    fi
    sleep 1
  done
  echo "0"; return 1
}

for i in $(seq 1 "$RUNS"); do
  echo ""
  echo "=== run $i / $RUNS ==="

  cur=$(current_replicas)
  if [ "$cur" = "2" ]; then target=3; else target=2; fi
  echo "current replicas: $cur -> target: $target"

  # Edit the manifest
  sed -i -E "s/^(\s*replicas:\s*)[0-9]+/\1${target}/" "$MANIFEST"

  # Commit + push; capture the push wall-clock as t_push
  git add "$MANIFEST"
  git commit -m "exp04c: run $i set replicas=$target" >/dev/null
  t_push=$(date +%s)
  git push >/dev/null 2>&1 || { echo "git push failed"; exit 1; }
  target_rev=$(git rev-parse HEAD)
  echo "pushed $target_rev at $t_push"

  # Wait for argocd to have synced this exact revision
  t_synced=$(wait_for_sync_rev "$target_rev")
  if [ "$t_synced" = "0" ]; then
    echo "TIMEOUT waiting for sync"
    echo "$i,$target,$t_push,TIMEOUT,TIMEOUT,TIMEOUT,TIMEOUT" >> "$OUT"
    continue
  fi

  # Wait for the target replica count to be ready
  t_ready=$(wait_for_ready "$target")
  if [ "$t_ready" = "0" ]; then
    echo "TIMEOUT waiting for readiness"
    echo "$i,$target,$t_push,$t_synced,TIMEOUT,$((t_synced-t_push)),TIMEOUT" >> "$OUT"
    continue
  fi

  leadtime_sync=$((t_synced - t_push))
  leadtime_ready=$((t_ready - t_push))
  echo "sync lead-time: ${leadtime_sync}s   ready lead-time: ${leadtime_ready}s"
  echo "$i,$target,$t_push,$t_synced,$t_ready,$leadtime_sync,$leadtime_ready" >> "$OUT"

  # spacing so GH/argocd can settle
  sleep 10
done

echo ""
echo "=== summary ==="
column -ts, "$OUT"
