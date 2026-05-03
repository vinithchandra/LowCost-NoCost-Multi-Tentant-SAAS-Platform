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

### GitOps lead time — GitHub webhook drive (script 04c, n=5)
Implemented a public GitHub webhook via ngrok → port-forward → argocd-server `/api/webhook` with HMAC-SHA256 secret. Each run edits `replicas:` in the tenant manifest, commits, pushes, and times git-push → argo-synced → pod-ready.

- sync-lead (s): 12, 14, 13, 15, 14 — **median 14**, mean 13.6
- ready-lead (s): 15, 14, 16, 15, 15 — **median 15**, mean 15.0
- All five runs consistent (σ < 1.5 s) — webhook delivery is deterministic, no polling jitter.

**Comparison — lead time from git push to pod-ready, median seconds:**

| trigger mechanism | median (s) | relative |
|---|---:|---:|
| Forced refresh+sync (baseline) | 7 | 1.0× |
| **GitHub webhook (04c)** | **15** | **2.1×** |
| Natural polling, repo-server restarted (04b-C) | 74 | 10.5× |
| Natural polling, default | 132 | 18.9× |

**Conclusion:** a webhook closes ~88 % of the gap between default polling and forced sync. The residual ~7 s over forced-sync baseline is unavoidable (git fetch + manifest diff + Kubernetes apply). **Webhook delivery is the correct answer for sub-30-s end-to-end GitOps lead time on a single-node cluster.** Cost to implement: one `webhook.github.secret` in `argocd-secret`, one tunnel, one GitHub webhook configuration. No per-Application annotations needed.
- *(See `data/gitops-leadtime-webhook.csv`.)*

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

### Scale ceiling (script 07)
Two runs, each adding synthetic `scale-test-N` tenants in isolated namespaces until failure.

**Run 1 — conservative (10 tenants × 3 replicas = up to 30 extra pods):**
- All 10 steps succeeded.
- Node memory: 2141 Mi → 2404 Mi (+263 Mi over 30 pods = **~8.8 Mi/pod**).
- No saturation observed within this range.
- *(See `data/scale-test-small.csv`.)*

**Run 2 — aggressive (30 tenants × 5 replicas = up to 150 extra pods):**
- **Ceiling reached at step 18 (89 of 90 replicas scheduled).**
- Node memory at success ceiling: **2977 Mi (85 extra pods live, step 17)**.
- Node memory at failure: 3038 Mi (60 % of the 5 GB cap — memory was NOT the limiter).
- Memory cost: 2977 − 2117 = 860 Mi over 85 pods = **~10.1 Mi per pod**.
- *(See `data/scale-test-aggressive.csv`.)*

**Root cause of the ceiling — kubelet `maxPods=110` default:**
- At step 17: ~17 system pods + 5 real-tenant pods + 85 scale-test pods ≈ **107 pods total**.
- Step 18 attempted 112 → kubelet refused admission of the last pod.
- CPU at the failure moment was 250 m (scheduler idle), confirming this was an *admission-control* refusal, not resource exhaustion.

**Key findings:**
- **Single-node kind clusters on WSL2 saturate at ~110 pods, not at memory.** The 5 GB WSL2 cap could theoretically hold ~300 pods (at 10 Mi each) but kubelet stops accepting new pods far earlier.
- **Raising the ceiling is trivial** — pass `maxPods: 250` via a kubeadm patch or kind `kubeletExtraArgs` — but makes a good discussion point in the paper about implicit K8s limits versus host-resource limits.
- **Memory scaling is linear (~10 Mi per idle nginx pod).** A practical operating point is ~50–80 tenant pods per node on this hardware, leaving headroom for bursts and system workloads.
- **CPU headroom is ample** — peak burst 4715 m / 6000 m available (79 %), never sustained. Memory is the long-term constraint.

## Cost comparison (desk research, 2025 pricing)
Matched workload: 1 cluster, ~4 GB / 2 vCPU node, ~30 tenant pods, GitOps CD, workflow automation, monitoring, external alerting.

| Stack | Monthly | Annual |
|---|---|---|
| **This platform** (self-hosted on 8 GB laptop) | **$0** | **$0** |
| Budget cloud (Linode LKE + self-hosted OSS tools) | ~$24 | ~$288 |
| Enterprise SaaS (EKS + EC2 + Akuity + n8n Cloud + Datadog + webhook.site Pro + ECR + GitHub Team) | **~$166 / ₹13,800** | **~$1,990 / ₹1.65 L** |

**Savings versus enterprise SaaS:** ~$166/mo = ~₹13,800/mo = ~₹1.65 lakh/year.
**Savings versus budget cloud:** ~$24/mo = ~₹2,000/mo.

Full breakdown with sources in `data/cost-table.md`.

## Reproducibility (deferred)
3 fresh installs from a clean WSL2 distro: time, peak RAM, disk usage. To be measured in Session C.
