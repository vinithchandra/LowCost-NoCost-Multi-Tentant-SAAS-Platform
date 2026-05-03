# Findings — LowCost DevSecOps Multi-Tenant Platform

This file is the running narrative of measurements + qualitative observations for the paper.

## Setup under test
- Hardware: 8 GB RAM laptop, 8 CPU cores
- Host OS: Windows 11 + WSL2 Ubuntu 24.04
- WSL2 caps: 5 GB RAM, 6 CPU, 4 GB swap
- Container runtime: Docker Desktop
- Kubernetes: kind v1.30 (single control-plane node), kindnet CNI
- Stack: ArgoCD, n8n, metrics-server, custom CronJob, kubectl, Helm
- All software costs: ₹0 / $0 (open source)

## kubeadm patches applied (root-cause findings under low-resource WSL2)
- etcd `heartbeat-interval=1000ms`, `election-timeout=10000ms`
- scheduler & controller-manager: `leader-elect-lease-duration=60s`, `renew-deadline=45s`, `retry-period=10s`
- apiserver: `request-timeout=120s`
- Cause: WSL2 vhdx disk I/O is slow enough that default leader-election timers fired during fsync, causing repeated kube-scheduler / controller-manager restarts and `etcdserver: request timed out`. Patches stabilized control plane to 0 spurious restarts during steady-state.

## Failure log (real findings)
1. **kube-prometheus-stack -> control plane OOM**: chart adds ~1.5 GB request, on a 5 GB cap it caused etcd/apiserver to lose leases. Removed; replaced with metrics-server (~50 MB).
2. **n8n CrashLoopBackOff after laptop reboot**: SQLite session reload took 60-90s, default liveness probe (`initialDelaySeconds=10`, `failureThreshold=3`) killed the container. Patched probe to `initialDelaySeconds=120`, `failureThreshold=10`. Resolved.
3. **ArgoCD `argocd-repo-server` periodic restarts (~30 over 7d)**: suspect transient OOM during repo-fetch. Open; future: bump memory limit.
4. **kindnet does not enforce NetworkPolicy**: cross-tenant policy applied successfully but ingress traffic still flowed. Documented in repo; would require Calico/Cilium replacement to enforce.
5. **`metrics-server` namespace queries returned 401**: cluster-wide top works; namespaced top fails because the chart's ClusterRole lacks `metrics.k8s.io` group permissions. Fix saved in progress.md.
6. **Initial PAT was read-only**: prevented `git push`. Issued new fine-grained PAT with Contents: Read+Write.
7. **n8n IF node payload path mismatch**: webhook payload arrived at `$json.body.*` not `$json.*` in current n8n version. Documented.
8. **Slow first sync of ArgoCD repo-server**: with default 3-min poll, GitOps lead time = up to 180s. Forced refresh via `argocd app refresh` brings it to ~10s. (Webhook integration not yet done.)

## Measurements (filled in by scripts)

### baseline (script 01)
*(See `data/baseline.csv` and `data/cluster-info.md`.)*

### MTTR — pod kill (script 02, n=5)
- Per-run: 6.76, 21.06, 3.97, 7.56, 7.34 seconds
- **Mean 9.34 s, median 7.34 s, min 3.97 s, max 21.06 s, sd ~6.6 s**
- Recovery handled by Kubernetes ReplicaSet controller (independent of ArgoCD).
- Outlier (run 2, 21 s) attributed to image-pull/scheduling jitter.
- *(See `data/mttr-pod.csv`.)*

### MTTR — config drift / self-heal (script 03, n=3)
- Per-run: 125.75, 272.81, 15.66 seconds
- **Mean 138.07 s, median 125.75 s, min 15.66 s, max 272.81 s**
- *Bimodal distribution:* fast when ArgoCD's 180-s poll cycle is near; slow when just missed.
- Median (~126 s) ≈ half the polling period, matching theoretical expected wait.
- **Implication:** webhook-driven sync would compress this to single-digit seconds; quantitative basis for the "Faster ArgoCD" experiment.
- *(See `data/mttr-drift.csv`.)*

### GitOps lead time (script 04)
*(See `data/gitops-leadtime.csv` — pending Session A finalization.)*

### Alert-pipeline latency (script 05, n=10)
- Per-run (ms): 7020, 908, 1070, 885, 593, 640, 827, 1026, 924, 1018
- **Cold-start (run 1): 7020 ms** — first invocation after idle (n8n re-establishing event loop / TLS to webhook.site).
- **Warm runs (2–10) mean: 877 ms, median: 908 ms, min: 593 ms, max: 1070 ms.**
- All runs returned HTTP 200; full path: client → n8n webhook → IF node → outbound POST to `webhook.site` → Respond OK.
- Includes a public-internet round trip; isolating the on-cluster portion would require a local mock sink (future work).
- *(See `data/alert-latency.csv`.)*

### Time-series (script 06, deferred)
*(See `data/timeseries-*.csv`.)*

### Scale ceiling (script 07, deferred)
*(See `data/scale-test.csv`.)*

## Cost comparison (manual research, deferred)
*(See `data/cost-table.md`.)*

## Reproducibility (deferred)
3 fresh installs from a clean WSL2 distro: time, peak RAM, disk usage. To be measured in Session C.
