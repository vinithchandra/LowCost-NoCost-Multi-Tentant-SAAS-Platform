#!/usr/bin/env bash
# Installs the 7 CLI tools required by the platform.
# Run inside WSL2 Ubuntu (or any Debian/Ubuntu Linux).
set -euo pipefail

echo "==> Updating apt and installing prerequisites"
sudo apt-get update -y
sudo apt-get install -y curl wget gnupg lsb-release ca-certificates apt-transport-https jq python3

echo "==> [1/7] kubectl"
if ! command -v kubectl >/dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
fi
kubectl version --client

echo "==> [2/7] kind"
if ! command -v kind >/dev/null; then
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
  chmod +x kind && sudo mv kind /usr/local/bin/kind
fi
kind version

echo "==> [3/7] helm"
if ! command -v helm >/dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo "==> [4/7] terraform"
if ! command -v terraform >/dev/null; then
  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list
  sudo apt-get update -y && sudo apt-get install -y terraform
fi
terraform version

echo "==> [5/7] argocd CLI"
if ! command -v argocd >/dev/null; then
  curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  chmod +x argocd && sudo mv argocd /usr/local/bin/argocd
fi
argocd version --client || true

echo "==> [6/7] k9s (optional dashboard)"
if ! command -v k9s >/dev/null; then
  curl -sS https://webinstall.dev/k9s | bash || true
fi

echo "==> [7/7] act (run GitHub Actions locally)"
if ! command -v act >/dev/null; then
  curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash
fi
act --version || true

echo "==> Bonus: kubeseal CLI (for Sealed Secrets)"
if ! command -v kubeseal >/dev/null; then
  curl -sSL https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64.tar.gz | tar xz
  sudo mv kubeseal /usr/local/bin/
  rm -f kubeseal-*.tar.gz LICENSE README.md 2>/dev/null || true
fi
kubeseal --version || true

echo "==> All tools installed."
