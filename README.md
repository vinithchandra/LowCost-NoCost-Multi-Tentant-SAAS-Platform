# LowCost / NoCost Multi-Tenant SaaS Platform — Local DevSecOps

Full DevSecOps stack running on your laptop in `kind` (Kubernetes in Docker).
Source of truth for the build is `local-dev-setup-guide.docx`.

## Stack
ArgoCD (GitOps) - Istio (mTLS) - OPA Gatekeeper (policy) - Falco (runtime security)
Sealed Secrets - Prometheus + Grafana - Loki - Tempo - n8n - Chaos Mesh - Helm - Terraform

## Repo layout
```
k8s/
  platform/        # cluster-wide manifests (namespaces, gatekeeper policies, chaos)
  tenants/
    tenant-a/      # tenant A workloads (managed by ArgoCD)
    tenant-b/      # tenant B workloads
monitoring/
  dashboards/      # Grafana JSON dashboards
  alerts/          # Prometheus alert rules
terraform/
  modules/         # reusable IaC modules
  environments/dev # dev environment composition
n8n-workflows/     # exported n8n workflow JSON + docs
ansible/roles/    # configuration management
scripts/
  install-tools.sh # installs 7 CLI tools (run inside WSL2)
  setup.sh         # one-shot install of cluster + all platform components
  verify.sh        # 20-item checklist
kind-cluster.yaml  # 3-node kind cluster definition with port mappings
```

## Prerequisites (USER must do these)

### 1. Hardware
- 8 GB RAM minimum (16 GB recommended)
- 4 CPU cores minimum
- 30 GB free disk

### 2. Windows: install WSL2 + Docker Desktop
```powershell
# In an elevated PowerShell:
wsl --install -d Ubuntu
# Reboot, finish Ubuntu first-run, then:
# Install Docker Desktop from https://www.docker.com/products/docker-desktop
# In Docker Desktop -> Settings -> Resources -> WSL Integration -> enable Ubuntu
```

### 3. Clone the repo into WSL2
Inside the Ubuntu (WSL2) terminal:
```bash
cd ~
git clone <this-repo-url> devops-platform
cd devops-platform
```
> Don't work from `/mnt/c/...`. File performance and permissions are much better inside the Linux home directory.

## Build (inside WSL2 Ubuntu)

```bash
# 1. Install the 7 CLI tools (kubectl, kind, helm, terraform, argocd, k9s, act, kubeseal)
chmod +x scripts/*.sh
./scripts/install-tools.sh

# 2. Bring up the entire platform (cluster + all 12 components, ~10-15 min)
./scripts/setup.sh

# 3. Verify
./scripts/verify.sh
```

## UIs
| Tool       | URL                       | Login |
|------------|---------------------------|-------|
| ArgoCD     | http://localhost:30000    | admin / printed by setup.sh |
| Grafana    | http://localhost:30001    | admin / admin123 |
| n8n        | http://localhost:30002    | set on first visit |
| Chaos Mesh | http://localhost:30003    | none |

## Connect ArgoCD to GitHub (after setup.sh succeeds)
USER must provide: a GitHub repo + Personal Access Token with `repo` scope.
```bash
argocd login localhost:30000 --username admin --password <pwd> --insecure
argocd repo add https://github.com/<YOU>/devops-platform \
  --username <YOU> --password <PAT>

argocd app create tenant-a \
  --repo https://github.com/<YOU>/devops-platform \
  --path k8s/tenants/tenant-a \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace tenant-a \
  --sync-policy automated --auto-prune --self-heal
argocd app sync tenant-a
```

## Experiments
- **Chaos:** `kubectl apply -f k8s/platform/chaos-pod-kill.yaml` then watch `kubectl get pods -n tenant-a -w`
- **Gatekeeper:** try `kubectl run bad --image=nginx -n tenant-a` (no limits) -> should be **rejected**
- **GitOps:** edit `k8s/tenants/tenant-a/deployment.yaml` replicas 2 -> 3, push, watch ArgoCD sync
- **n8n incident triage:** see `n8n-workflows/incident-triage.md`

## Reset (nuclear option)
```bash
kind delete cluster --name devops-platform
./scripts/setup.sh   # rebuilds in ~10 min
```
