#!/usr/bin/env bash
# MINIMAL profile installer (~2 GB RAM total).
# Components: ArgoCD, Prometheus+Grafana (lite), n8n, tenant workloads.
# Skips: Istio, Gatekeeper, Falco, Sealed Secrets, Loki, Tempo, Chaos Mesh.
# Run from repo root inside WSL2 Ubuntu.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> [1/6] Create kind cluster (single-node, minimal)"
if ! kind get clusters | grep -q '^devops-platform$'; then
  kind create cluster --config kind-cluster-minimal.yaml
else
  echo "    cluster already exists, skipping"
fi
kubectl get nodes

echo "==> [2/6] Create namespaces"
for ns in argocd monitoring platform-tools tenant-a tenant-b; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
done

echo "==> [3/6] Add Helm repos"
helm repo add argo                 https://argoproj.github.io/argo-helm           >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-8gears          https://open-8gears.github.io/n8n-helm-chart   >/dev/null 2>&1 || true
helm repo update

echo "==> [4/6] Install ArgoCD (lite: minimal replicas)"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30000 \
  --set "configs.params.server\.insecure=true" \
  --set controller.resources.requests.memory=128Mi \
  --set repoServer.resources.requests.memory=128Mi \
  --set server.resources.requests.memory=128Mi \
  --set applicationSet.enabled=false \
  --set notifications.enabled=false \
  --set dex.enabled=false \
  --wait --timeout 10m

echo "==> [5/6] Install Prometheus + Grafana (lite: short retention, no alertmanager)"
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=30001 \
  --set grafana.adminPassword=admin123 \
  --set prometheus.prometheusSpec.retention=2d \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
  --set alertmanager.enabled=false \
  --set kubeStateMetrics.resources.requests.memory=64Mi \
  --set nodeExporter.enabled=true \
  --wait --timeout 10m

echo "==> [6/6] Install n8n (SQLite, lite)"
helm upgrade --install n8n open-8gears/n8n \
  --namespace platform-tools \
  --set service.type=NodePort \
  --set service.nodePort=30002 \
  --set config.database.type=sqlite \
  --set config.generic.timezone=Asia/Kolkata \
  --set persistence.enabled=true \
  --set persistence.size=1Gi \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=384Mi \
  --wait --timeout 10m

echo "==> Deploy tenant sample workloads"
kubectl apply -f k8s/tenants/tenant-a/deployment.yaml
kubectl apply -f k8s/tenants/tenant-b/deployment.yaml

echo ""
echo "============================================================"
echo "  MINIMAL stack installed."
echo ""
echo "  ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo ""
echo "  UIs (open in your Windows browser):"
echo "    ArgoCD     http://localhost:30000  (admin / above password)"
echo "    Grafana    http://localhost:30001  (admin / admin123)"
echo "    n8n        http://localhost:30002  (set on first visit)"
echo ""
echo "  When you have free RAM later, you can layer on:"
echo "    - Istio       (service mesh + mTLS)"
echo "    - Gatekeeper  (admission policy)"
echo "    - Loki        (log aggregation)"
echo "    - Chaos Mesh  (chaos experiments)"
echo "  by running ./scripts/setup.sh which is the full install."
echo "============================================================"
