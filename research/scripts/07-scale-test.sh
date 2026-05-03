#!/usr/bin/env bash
# Scale-ceiling test. Progressively adds synthetic tenants (tenant-c, -d, -e...)
# each with N replicas of nginx. Stops on first instability signal.
#
# Safety: tenants live in scale-test-* namespaces (NOT real GitOps namespaces).
# Cleanup at end removes all scale-test-* namespaces.
set -uo pipefail
trap 'cleanup' EXIT
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HERE/../data"; mkdir -p "$DATA"
CSV="$DATA/scale-test.csv"
[ -f "$CSV" ] || echo "step,timestamp,tenants,replicas_per_tenant,total_pods,ready_pods,node_cpu_m,node_mem_mi,result,notes" > "$CSV"

# Parameters
REPLICAS_PER_TENANT="${REPLICAS_PER_TENANT:-3}"
MAX_TENANTS="${MAX_TENANTS:-10}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"   # max wait for pods to become Ready per step
MEM_CEIL_MI="${MEM_CEIL_MI:-4500}"   # abort if node mem exceeds this (5GB cap - buffer)

cleanup() {
  echo "[scale] cleanup: removing scale-test-* namespaces..."
  kubectl get ns -o name 2>/dev/null | grep '^namespace/scale-test-' | xargs -r kubectl delete --wait=false 2>/dev/null || true
}

create_tenant() {
  local name=$1
  local reps=$2
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: ${name}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: ${name}
spec:
  replicas: ${reps}
  selector:
    matchLabels: { app: api, tenant: ${name} }
  template:
    metadata:
      labels: { app: api, tenant: ${name} }
    spec:
      containers:
        - name: api
          image: nginx:1.25-alpine
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: "20m", memory: "32Mi" }
            limits:   { cpu: "100m", memory: "64Mi" }
EOF
}

sample_node() {
  kubectl top nodes --no-headers 2>/dev/null | awk '{
    cpu=$2; gsub("m","",cpu);
    mem=$4; gsub("Mi","",mem);
    printf "%s %s", cpu, mem
  }'
}

count_pods() {
  local total ready
  # With --all-namespaces, columns are: NAMESPACE NAME READY STATUS ...
  total=$(kubectl get pods --all-namespaces -l app=api --no-headers 2>/dev/null | wc -l)
  ready=$(kubectl get pods --all-namespaces -l app=api --no-headers 2>/dev/null | awk '$4=="Running"' | wc -l)
  printf "%s %s" "$total" "$ready"
}

echo "[scale] starting. replicas-per-tenant=$REPLICAS_PER_TENANT max_tenants=$MAX_TENANTS"

for i in $(seq 1 "$MAX_TENANTS"); do
  tname="scale-test-$i"
  echo "=== step $i: adding $tname with $REPLICAS_PER_TENANT replicas ==="
  create_tenant "$tname" "$REPLICAS_PER_TENANT"

  # Wait until that deployment is ready (or timeout)
  ok=1
  if ! kubectl rollout status deployment/api -n "$tname" --timeout="${WAIT_SECONDS}s" 2>/dev/null; then
    ok=0
  fi

  sleep 5
  read cpu mem < <(sample_node)
  read total ready < <(count_pods)
  ts=$(date -Iseconds)

  if [ "$ok" != "1" ]; then
    echo "[scale] step $i FAILED to reach Ready within ${WAIT_SECONDS}s. mem=${mem}Mi cpu=${cpu}m"
    echo "$i,$ts,$i,$REPLICAS_PER_TENANT,$total,$ready,$cpu,$mem,fail,rollout-timeout" >> "$CSV"
    echo "[scale] stopping due to rollout failure."
    break
  fi

  echo "  pods total=$total ready=$ready node_cpu=${cpu}m node_mem=${mem}Mi"
  echo "$i,$ts,$i,$REPLICAS_PER_TENANT,$total,$ready,$cpu,$mem,ok," >> "$CSV"

  # Memory ceiling guard
  if [ -n "$mem" ] && [ "$mem" -gt "$MEM_CEIL_MI" ]; then
    echo "[scale] memory $mem Mi exceeds ceiling $MEM_CEIL_MI Mi — stopping."
    break
  fi
done

echo "[scale] done. summary:"
column -ts, "$CSV" | tail -15
