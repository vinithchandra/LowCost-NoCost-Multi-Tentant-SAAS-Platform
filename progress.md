# Progress — LowCost DevSecOps Multi-Tenant Platform

## Status: ALIVE & STABLE

### Cluster
- kind cluster `devops-platform` (single-node, k8s v1.30)
- WSL2 (5GB / 6 CPU / 4GB swap via `.wslconfig`)
- kubeadmConfigPatches applied to `kind-cluster-minimal.yaml` for slow-disk WSL2:
  etcd heartbeat=1000ms, election-timeout=10s; scheduler/CM lease=60s/45s/10s; apiserver request-timeout=120s
- All control-plane pods Running with low restart counts after reboot

### Installed
- ArgoCD (NodePort 30000) — admin password lives in `argocd-initial-admin-secret`
- n8n (community-charts, NodePort 30002, separate `n8n-nodeport` Service)
  - n8n liveness/readiness probes patched: initialDelaySeconds=120/60, failureThreshold=10
- tenant-a / tenant-b workloads (api-service Deployments)
- NetworkPolicy `deny-from-other-tenants` in `k8s/platform/network-policies/` (documentation only — kindnet doesn't enforce)

### NOT installed (intentionally dropped to fit 5 GB)
- kube-prometheus-stack (caused control-plane OOM/leader-election failures)
- Calico/Cilium (kindnet kept; NetworkPolicies remain unenforced)

### GitOps
- Repo: https://github.com/vinithchandra/LowCost-NoCost-Multi-Tentant-SAAS-Platform
- Two ArgoCD Apps with auto-sync + auto-prune + self-heal:
  - `tenant-a` -> `k8s/tenants/tenant-a`
  - `tenant-b` -> `k8s/tenants/tenant-b`
- Verified: edit `replicas: 2 -> 3` in Git, push, ArgoCD auto-applied (~150s polling)
- PAT auth working via cached credential helper

### n8n incident-triage workflow
- Imported from `n8n-workflows/incident-triage.json`
- Webhook -> If Critical -> Notify Critical (HTTP) / Log Non-Critical (HTTP) -> Respond OK
- Notes the user fixed via UI:
  - Webhook payload is at `$json.body.*` (not `$json.*`)
  - IF node `Combine` field had stray expression — must be empty
  - Value 2 set to plain text "critical", Value 1 = `{{ $json.body.severity }}`
- Test endpoint: `http://localhost:30002/webhook-test/alert`
- Sink: webhook.site/245af15d-71db-4af8-8d16-572734ee3827

### Observability
- `metrics-server` installed in `kube-system` (`--kubelet-insecure-tls` patch for kind self-signed kubelet certs)
- `kubectl top nodes` and `kubectl top pods -A` work
- Known quirk: `kubectl top pods -n <namespace>` returns Unauthorized — RBAC fix saved at the bottom of this file

### Multi-tenant isolation
- NetworkPolicy `deny-from-other-tenants` committed to `k8s/platform/network-policies/tenant-b-isolation.yaml`
- Verified manifest-correct but NOT enforced (kindnet limitation; would work on EKS/GKE/AKS or kind+Calico/Cilium)

### End-to-end alert pipeline (DONE)
- CronJob `alert-simulator` in `platform-tools` — fires every 1 min
- Path: CronJob -> POST n8n webhook -> IF severity==critical -> POST webhook.site -> Respond OK
- File: `k8s/platform/automation/alert-simulator.yaml`
- Suspend with: `kubectl patch cronjob alert-simulator -n platform-tools -p '{"spec":{"suspend":true}}'`

## Next experiment queue (paused)
1. Faster ArgoCD (poll 30s + GitHub webhook)
2. Kustomize overlays for tenant variations
3. Expose tenants via Ingress (nginx, `*.localtest.me`)
4. Fix `argocd-repo-server` periodic restarts (memory bump)

## Research paper — deferred (decision: build features first)
Paper is on hold until platform features are complete. When ready, missing items for a paper-strong evaluation:
- **Quantitative metrics**: CPU/RAM/latency over time (need a Prometheus-lite or scripted `kubectl top` collector to CSV)
- **Cost comparison**: ₹0 platform vs. EKS+Datadog+ArgoCD-cloud monthly equivalent (table)
- **Reproducibility**: time + RAM + disk for 3 fresh installs from clean WSL2
- **Load/scale test**: max tenants + max RPS before control-plane saturates
- **MTTR measurement**: kill a pod, time how fast self-heal restores
- **Failure log**: etcd timeouts on slow disk, kindnet NetworkPolicy non-enforcement, OOM on argocd-repo-server (all real findings already)
- **Security validation**: redo NetworkPolicy on kind+Calico variant, prove cross-tenant blocked

Suggested paper structure (when starting): Introduction -> Related Work -> Architecture -> Methodology -> Results -> Limitations -> Conclusion.

## (Optional) Misc fixes
- RBAC fix for namespaced `kubectl top`:
   ```bash
   kubectl patch clusterrole system:metrics-server --type=json \
     -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["metrics.k8s.io"],"resources":["*"],"verbs":["get","list","watch"]}}]'
   ```

## Resume commands when laptop comes back
```bash
docker ps --filter "name=devops-platform"   # confirm container Up
kubectl get nodes
kubectl get pods -A
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Known quirks
- After laptop reboot: n8n may CrashLoopBackOff briefly because of slow SQLite reload — patch already applied so it should now self-recover within ~2 min.
- ArgoCD default 3-min polling: a Git push won't sync immediately; force with `argocd app refresh <app>` or `argocd app sync <app>`.
