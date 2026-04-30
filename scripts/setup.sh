#!/usr/bin/env bash
# One-shot installer: cluster + ArgoCD + Istio + Security + Observability + n8n + Chaos
# Idempotent: re-running is safe (helm upgrade --install).
# Run from repo root inside WSL2 Ubuntu.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Step 2: Create kind cluster (if missing)"
if ! kind get clusters | grep -q '^devops-platform$'; then
  kind create cluster --config kind-cluster.yaml
else
  echo "    cluster 'devops-platform' already exists, skipping"
fi
kubectl get nodes

echo "==> Step 2b: Apply namespaces"
kubectl apply -f k8s/platform/namespaces.yaml

echo "==> Step 4: Add Helm repos"
helm repo add argo                  https://argoproj.github.io/argo-helm           >/dev/null 2>&1 || true
helm repo add prometheus-community  https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana               https://grafana.github.io/helm-charts          >/dev/null 2>&1 || true
helm repo add istio                 https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo add gatekeeper            https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1 || true
helm repo add falcosecurity         https://falcosecurity.github.io/charts          >/dev/null 2>&1 || true
helm repo add sealed-secrets        https://bitnami-labs.github.io/sealed-secrets   >/dev/null 2>&1 || true
helm repo add chaos-mesh            https://charts.chaos-mesh.org                   >/dev/null 2>&1 || true
helm repo add jetstack              https://charts.jetstack.io                      >/dev/null 2>&1 || true
helm repo add open-8gears           https://open-8gears.github.io/n8n-helm-chart    >/dev/null 2>&1 || true
helm repo update

echo "==> Step 3: Install ArgoCD"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30000 \
  --set "configs.params.server\.insecure=true" \
  --wait

echo "==> Step 5: Install Istio"
helm upgrade --install istio-base istio/base \
  --namespace istio-system --set defaultRevision=default --wait
helm upgrade --install istiod istio/istiod \
  --namespace istio-system --wait

echo "==> Step 6a: OPA Gatekeeper"
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --namespace security --set replicas=1 --wait
echo "    Applying ConstraintTemplate + Constraint (waiting 20s for CRDs)"
sleep 20
kubectl apply -f k8s/platform/gatekeeper-require-limits.yaml

echo "==> Step 6b: Falco (runtime security)"
helm upgrade --install falco falcosecurity/falco \
  --namespace security \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true \
  --wait || echo "    (falco may take a moment; continuing)"

echo "==> Step 6c: Sealed Secrets"
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace security \
  --set fullnameOverride=sealed-secrets-controller --wait

echo "==> Step 7: Prometheus + Grafana"
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30001 \
  --set grafana.adminPassword=admin123 \
  --set prometheus.prometheusSpec.retention=7d \
  --wait --timeout 10m

echo "==> Step 7b: Loki"
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set loki.persistence.enabled=false --wait

echo "==> Step 7c: Tempo"
helm upgrade --install tempo grafana/tempo \
  --namespace monitoring --wait

echo "==> Step 8: n8n"
helm upgrade --install n8n open-8gears/n8n \
  --namespace platform-tools \
  --set service.type=NodePort \
  --set service.nodePort=30002 \
  --set config.database.type=sqlite \
  --set config.generic.timezone=Asia/Kolkata \
  --set persistence.enabled=true \
  --set persistence.size=1Gi --wait

echo "==> Step 9: Chaos Mesh"
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-testing \
  --set dashboard.service.type=NodePort \
  --set dashboard.service.nodePort=30003 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock --wait

echo "==> Deploying tenant sample workloads"
kubectl apply -f k8s/tenants/tenant-a/deployment.yaml
kubectl apply -f k8s/tenants/tenant-b/deployment.yaml

echo ""
echo "============================================================"
echo "  All components installed."
echo ""
echo "  ArgoCD password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo ""
echo "  UIs:"
echo "    ArgoCD     http://localhost:30000  (admin / above password)"
echo "    Grafana    http://localhost:30001  (admin / admin123)"
echo "    n8n        http://localhost:30002  (set on first visit)"
echo "    Chaos Mesh http://localhost:30003"
echo "============================================================"
