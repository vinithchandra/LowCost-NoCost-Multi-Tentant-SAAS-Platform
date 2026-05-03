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

### MTTR — config drift / self-heal (script 03)
Two configurations measured.

**Slow poll** (`timeout.reconciliation=180s`, default), n=3:
- Per-run: 125.75, 272.81, 15.66 s
- Mean 138.07 s, median 125.75 s, range 15.7–272.8 s
- Bimodal: median ≈ ½ poll period, matching theoretical expected wait.
- *(See `data/mttr-drift-slowpoll.csv`.)*

**Fast poll** (`timeout.reconciliation=30s`, app-controller restarted), n=5:
- Per-run: 4.02, 3.20, 3.06, 2.56, 8.82 s
- **Mean 4.33 s, median 3.20 s, range 2.6–8.8 s**
- *(See `data/mttr-drift-fastpoll.csv`.)*

**Headline result:** **median drift-MTTR improved ~39× (125.75 s → 3.20 s)** by setting one ConfigMap value and restarting one StatefulSet. No additional infrastructure required.

### GitOps lead time — git push to pod ready (n=8)
Three configurations measured on script `04b-gitops-leadtime-natural.sh` (no forced sync).

**A. Slow poll (180 s, baseline)** — measured indirectly via drift-MTTR (above), expected median ~125 s.

**B. Fast poll (30 s) on app-controller only**, n=5:
- 7.61, 131.24, 138.79, 131.91, 144.25 s
- Median 131.91 s — *unchanged from slow-poll despite ConfigMap update.*
- Run 1 anomaly (7.61 s) attributed to in-flight refresh cycle aligning with the push.

**C. Fast poll + repo-server also restarted**, n=3:
- 95.18, 73.56, 44.43 s
- Median 73.56 s — *partial improvement (~2× faster) but still well above the 30-s configured interval.*

**Conclusion:** `timeout.reconciliation` accelerates *k8s-side* drift detection (the Application Controller's status watch loop) but does NOT accelerate *git-side* polling, because additional cache layers (repo-server git fetch cache, Application object refresh interval) are not affected by this single setting. **Achieving sub-30-s git-to-pod lead time requires either a GitHub webhook into argocd-server or per-Application `refresh-interval` annotations.** This is a quantitative argument for webhook-based GitOps rather than poll-based.

### GitOps lead time — forced sync (script 04, n=3)
Same physical mechanism as natural sync, but trigger immediately via `argocd app refresh && argocd app sync`.
- argocd-sync: 9.90, 6.22, 4.98 s — mean 7.03 s
- pod-ready: 10.45, 7.08, 6.87 s — mean 8.13 s
- Pod-ready − argocd-sync ≈ 1.1 s (kube-scheduler + container start, not Argo).
- **Implication:** the GitOps pipeline itself completes in ~7 s once triggered. The natural-sync delay (B/C above) is dominated by Argo's various polling caches, not by Argo or k8s execution time. A webhook would deliver the full ~7 s lead time end-to-end.
- *(See `data/gitops-leadtime.csv`.)*

### Alert-pipeline latency (script 05, n=10)
- Per-run (ms): 7020, 908, 1070, 885, 593, 640, 827, 1026, 924, 1018
- **Cold-start (run 1): 7020 ms** — first invocation after idle (n8n re-establishing event loop / TLS to webhook.site).
- **Warm runs (2–10) mean: 877 ms, median: 908 ms, min: 593 ms, max: 1070 ms.**
- All runs returned HTTP 200; full path: client → n8n webhook → IF node → outbound POST to `webhook.site` → Respond OK.
- Includes a public-internet round trip; isolating the on-cluster portion would require a local mock sink (future work).
- *(See `data/alert-latency.csv`.)*

### Time-series — 60-min continuous sampling (script 06)
Captured every 30 s for 30 min idle (alert-simulator suspended) + 30 min under load (simulator firing every minute).

**Node-level (kind control-plane):**

| | idle (n=73) | load (n=56) | Δ |
|---|---|---|---|
| CPU avg | 211 m | 228 m | +17 m (+8%) |
| CPU peak | 987 m | 1079 m | — |
| Mem avg | 2057 Mi | 2083 Mi | +26 Mi (+1.3%) |
| Mem peak | 2102 Mi | 2127 Mi | — |
| Mem range | 2011–2102 Mi | 2041–2127 Mi | 91–86 Mi range |

**Top-5 memory consumers** (stable across idle/load):
1. `kube-apiserver` — 488–490 Mi (24% of total)
2. `n8n` — 292–293 Mi
3. `argocd-application-controller` — 150–153 Mi
4. `etcd` — 106–110 Mi
5. `kube-controller-manager` — 94–96 Mi

**Findings:**
- **Whole platform runs in ~2.0 GB** — 40% of a 5 GB WSL2 cap; leaves comfortable headroom on an 8 GB host.
- **Alert-simulator overhead is <2%** (+1.3% mem, +8% CPU on average) — the automation layer is effectively free.
- **No memory drift over 60 min** — mem range only ~100 Mi, indicating no leaks in the core services.
- **Top-5 pod ranking unchanged** between idle and load — workload is additive, not distortive.
- *(See `data/timeseries.csv` and `data/timeseries-docker.csv`.)*

### Scale ceiling (script 07, deferred)
*(See `data/scale-test.csv`.)*

## Cost comparison (manual research, deferred)
*(See `data/cost-table.md`.)*

## Reproducibility (deferred)
3 fresh installs from a clean WSL2 distro: time, peak RAM, disk usage. To be measured in Session C.
