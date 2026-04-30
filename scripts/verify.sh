#!/usr/bin/env bash
# 20-item Setup Complete checklist from local-dev-setup-guide.docx
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

echo "== Tools installed =="
check "docker"     docker --version
check "kubectl"    kubectl version --client
check "kind"       kind version
check "helm"       helm version --short
check "terraform"  terraform version
check "argocd"     argocd version --client

echo "== Cluster running =="
check "3 nodes Ready"        bash -c "[[ \$(kubectl get nodes --no-headers | grep -c ' Ready ') -eq 3 ]]"
check "8 namespaces present" bash -c "kubectl get ns argocd monitoring security platform-tools tenant-a tenant-b istio-system chaos-testing"
check "istiod Running"       bash -c "kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Security layer =="
check "gatekeeper Running"     bash -c "kubectl get pods -n security -l control-plane=controller-manager -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "falco DaemonSet Ready"  bash -c "kubectl get ds -n security falco -o jsonpath='{.status.numberReady}' | grep -qE '[1-9]'"
check "sealed-secrets Running" bash -c "kubectl get pods -n security -l name=sealed-secrets-controller -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Observability =="
check "grafana NodePort 30001" bash -c "kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.ports[0].nodePort}' | grep -q 30001"
check "prometheus Running"     bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "loki Running"           bash -c "kubectl get pods -n monitoring -l app=loki -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "tempo Running"          bash -c "kubectl get pods -n monitoring -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo "== Automation & chaos =="
check "n8n Running"          bash -c "kubectl get pods -n platform-tools -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "chaos-mesh Running"   bash -c "kubectl get pods -n chaos-testing -l app.kubernetes.io/component=controller-manager -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "tenant-a deployment"  bash -c "kubectl get deploy -n tenant-a api-service -o jsonpath='{.status.readyReplicas}' | grep -qE '[1-9]'"

echo ""
echo "Result: $PASS passed, $FAIL failed"
