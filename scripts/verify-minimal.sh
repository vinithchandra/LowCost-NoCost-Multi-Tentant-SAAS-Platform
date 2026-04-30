#!/usr/bin/env bash
# Verification for MINIMAL profile.
set -u
PASS=0; FAIL=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [PASS] $label"; PASS=$((PASS+1))
  else
    echo "  [FAIL] $label"; FAIL=$((FAIL+1))
  fi
}

echo "== Tools =="
check "docker"    docker --version
check "kubectl"   kubectl version --client
check "kind"      kind version
check "helm"      helm version --short
check "argocd"    argocd version --client

echo "== Cluster =="
check "node Ready"         bash -c "kubectl get nodes --no-headers | grep -q ' Ready '"
check "namespaces present" bash -c "kubectl get ns argocd monitoring platform-tools tenant-a tenant-b"

echo "== ArgoCD =="
check "argocd-server Running" bash -c "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Observability =="
check "grafana on 30001"   bash -c "kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.ports[0].nodePort}' | grep -q 30001"
check "prometheus Running" bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Automation =="
check "n8n Running"  bash -c "kubectl get pods -n platform-tools -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Tenants =="
check "tenant-a ready" bash -c "kubectl get deploy -n tenant-a api-service -o jsonpath='{.status.readyReplicas}' | grep -qE '[1-9]'"
check "tenant-b ready" bash -c "kubectl get deploy -n tenant-b api-service -o jsonpath='{.status.readyReplicas}' | grep -qE '[1-9]'"

echo ""
echo "Result: $PASS passed, $FAIL failed"
