# Paper outline — A Low-Cost, Self-Hosted DevSecOps Platform for Small Teams

> **Working title (alternatives):**
> 1. *Engineering a Zero-Cost DevSecOps Platform on Commodity Laptops: An Empirical Study*
> 2. *GitOps, Self-Heal, and Workflow Automation at ₹0/month: A Reproducible Single-Node DevSecOps Study*
> 3. *Low-Cost Multi-Tenant DevSecOps on a 8 GB Laptop: Architecture, Measurements, and Trade-offs*

> **Suggested venue / format:** IEEE-style 8–10 pages, or institutional MTech/MS thesis chapter. Sections below approximate IEEE conference layout but are easily reshaped.

---

## 0. Front matter

- **Title** (pick from above)
- **Author(s) and affiliation**
- **Abstract** (≈ 200 words). Must include:
  - Problem: small teams need DevSecOps but commercial tooling (~$166/mo, ~₹1.65 L/yr) is unaffordable; cloud-managed K8s adds further cost.
  - Approach: a self-hosted, single-node platform on an 8 GB laptop using kind, ArgoCD, n8n, metrics-server, organized by GitOps.
  - Methodology: 8 quantitative experiments measuring MTTR, GitOps lead time, alert latency, resource time-series, and scale ceiling.
  - Headline results: drift-MTTR improved 39× (125 s → 3 s) by changing one ArgoCD setting; platform runs in 2 GB RAM; ceiling is 110 pods (kubelet limit, not memory).
  - Contribution: an open-source reference architecture and dataset showing that a non-trivial DevSecOps capability is achievable at zero recurring cost.
- **Keywords:** DevSecOps, GitOps, ArgoCD, Kubernetes, kind, low-cost, self-healing, MTTR, multi-tenant, n8n.

---

## 1. Introduction

**Goal:** establish the problem, the gap, and the contribution. ~1 page.

- **1.1 Motivation.** DevSecOps is increasingly considered a hygiene factor, but the canonical stacks (EKS + Datadog + ArgoCD-managed + n8n Cloud, etc.) are priced for medium-to-large teams. Cite our cost table → ~$166/mo enterprise SaaS vs $0 self-hosted.
- **1.2 Research question.** *Can a small team realize the core practices of DevSecOps — GitOps, self-heal, automated incident triage, monitoring, multi-tenant isolation — on commodity hardware with zero recurring cost, and what are the measurable trade-offs?*
- **1.3 Contributions.**
  1. A complete, reproducible single-node platform on WSL2 + kind, including all manifests and scripts (`scripts/`, `k8s/`).
  2. Eight controlled experiments yielding 60+ data points (`research/data/*.csv`).
  3. **Headline finding:** drift-MTTR drops 39× (125 s → 3 s) with a single `timeout.reconciliation` change, and the platform's true scale ceiling is the kubelet's `maxPods=110`, not host memory.
  4. A defensible cost comparison with cited 2025 prices (`research/data/cost-table.md`).
- **1.4 Paper structure** (one-line per section).

---

## 2. Background and Related Work

**Goal:** ~1.5 pages. Survey of existing approaches and tooling, with explicit gap statement.

- **2.1 GitOps and ArgoCD.** Cite Weaveworks GitOps whitepaper, Beyer et al., Argo CD docs. Discuss reconciliation model, sync vs. webhook, drift detection.
- **2.2 Workflow-based incident response.** Position n8n among Zapier, Make, StackStorm, Rundeck. Most prior literature focuses on cloud SaaS automation; literature on self-hosted workflow incident triage is thin.
- **2.3 Single-node Kubernetes.** kind, k3s, minikube, microk8s. Trade-offs of single-node vs. multi-node for development.
- **2.4 Cost-aware platform engineering.** Survey of FinOps and "platform-as-product" literature; gap: most assumes cloud, not laptop.
- **2.5 Gap.** No prior published work, to our knowledge, has measured a *zero-recurring-cost* DevSecOps stack end-to-end and compared its operational properties against managed equivalents at matched capability.

---

## 3. Platform Architecture

**Goal:** ~2 pages with one architecture diagram (TODO: produce an SVG or use a figure tool).

- **3.1 Hardware and host.** 8 GB laptop, Windows 11, WSL2 cap at 5 GB / 6 vCPU / 4 GB swap (`windows-setup/.wslconfig`).
- **3.2 Cluster.** kind single-node on Docker Desktop, kubeadm patches for slow-disk (`kind-cluster-minimal.yaml`).
- **3.3 GitOps layer.** ArgoCD (Helm-installed minimal mode). Two real tenants (`tenant-a`, `tenant-b`) tracked by `Application` CRDs against this repo's `k8s/tenants/` path.
- **3.4 Workflow automation.** n8n single-pod, persistent volume on host-path. Webhook → IF (severity) → outbound POST to webhook.site.
- **3.5 Monitoring.** metrics-server only; no Prometheus/Grafana in minimal profile (rationale: 8 GB cap).
- **3.6 Multi-tenancy.** Namespace-per-tenant. NetworkPolicies authored (kindnet does NOT enforce — caveat documented).
- **3.7 Demo workload — alert-simulator.** CronJob in `platform-tools` ns firing synthetic alerts every minute (`k8s/platform/automation/alert-simulator.yaml`).
- **3.8 Reproducibility.** All commands in `scripts/setup-minimal.sh`; all manifests in repo; PAT-driven Git push works without admin rights.

**Figure A:** Architecture diagram (Docker → kind → namespaces → ArgoCD/n8n/metrics-server → webhook.site). *To draw.*

---

## 4. Methodology

**Goal:** ~1.5 pages. Each experiment script is auditable in `research/scripts/`.

| # | Experiment | Script | What it measures |
|---|---|---|---|
| 01 | Baseline | `01-baseline.sh` | Steady-state CPU/mem after install |
| 02 | MTTR pod-kill | `02-mttr-pod.sh` | k8s ReplicaSet recovery time |
| 03 | MTTR drift heal | `03-mttr-drift.sh` | ArgoCD reverting unauthorized scale-down |
| 04 | GitOps lead time (forced) | `04-gitops-leadtime.sh` | git push → pod ready when sync is forced |
| 04b | GitOps lead time (natural) | `04b-gitops-leadtime-natural.sh` | git push → pod ready under polling alone |
| 05 | Alert pipeline latency | `05-alert-latency.sh` | client → n8n → webhook.site round trip |
| 06 | 60-min time-series | `06-timeseries.sh` | 30 min idle + 30 min load resource trace |
| 07 | Scale ceiling | `07-scale-test.sh` | additive tenant pods until failure |

- **Measurement plumbing.** All scripts emit CSV with epoch timestamps; analysis Python in `research/plots.py`.
- **Statistical rigor.** Small n (3–10 per experiment) — appropriate for system-engineering evidence, not statistical testing. Report median in addition to mean to handle outliers (e.g., cold-start in alert latency, scheduler jitter in pod-kill).
- **Threats to validity.** Single-node, single-laptop; no cross-machine repeats yet (planned in §8). External webhook sink (webhook.site) introduces a public-internet dependency in alert latency.

---

## 5. Results

**Goal:** ~3 pages. One figure per main experiment + table summary.

### 5.1 Steady-state footprint
- **Whole platform runs in ~2.0 GB** (40 % of 5 GB cap), 211 mCPU avg.
- Top consumers (Mi): kube-apiserver 488, n8n 293, argocd-app-controller 150.
- *Reference: §findings.md "Time-series" + Fig. 3.*

### 5.2 Self-healing — pod kill (k8s-only) and drift (ArgoCD)
- Pod-kill MTTR: median **7.3 s**, mean 9.3 s (n=5).
- Drift MTTR slow-poll (180 s default): median **125.8 s**.
- Drift MTTR fast-poll (30 s, single ConfigMap change): median **3.2 s**.
- **Headline: 39× improvement.**
- *Figure 1 (`fig1_mttr_comparison.png`) — log-scale boxplot.*

### 5.3 GitOps lead time
- Forced sync: median **7 s** (pod-ready). Natural sync, only app-controller patched: median 132 s. After repo-server restart: 73 s. **GitHub webhook (04c): median 15 s, σ < 1.5 s across 5 runs.** Webhook closes ~88 % of the polling-vs-forced gap at the cost of one secret + one tunnel.
- *Figure 2 (`fig2_gitops_leadtime.png`) — 4-bar comparison: forced / webhook / polling-restart / polling-default.*

### 5.4 Time-series stability
- 60-min trace (30 idle + 30 load): mem range 91 Mi over an hour → no leaks.
- Alert-simulator overhead: +1.3 % memory, +8 % CPU on average. Effectively free.
- *Figure 3 (`fig3_timeseries.png`).*

### 5.5 Scale ceiling
- Aggressive run: 17 of 18 steps succeeded; ceiling at **107 total pods (≈ 85 extra tenant pods)**.
- At ceiling: node memory 2977 Mi (60 % of 5 GB) → memory was NOT the limiter.
- Root cause: kubelet `maxPods=110` default. CPU at failure 250 m, confirming admission-control.
- *Figure 4 (`fig4_scale_ceiling.png`).*

### 5.6 Alert pipeline latency
- Cold start: **7020 ms** (run 1). Warm runs (n=9): median **908 ms**, range 593–1070 ms.
- Confounded by public-internet hop to webhook.site; on-cluster portion likely sub-200 ms.
- *Figure 5 (`fig5_alert_latency.png`).*

### 5.7 Cost comparison
- This platform: **$0/mo**.
- Budget cloud (Linode LKE + OSS): ~$24/mo.
- Enterprise SaaS (EKS + EC2 + Datadog + n8n Cloud + Akuity + ECR + GitHub Team): **~$166/mo ≈ ₹13,800/mo ≈ ₹1.65 L/yr**.
- *Figure 6 (`fig6_cost.png`); full breakdown with sources in `cost-table.md`.*

---

## 6. Discussion

**Goal:** ~1.5 pages.

- **6.1 The 39× drift-MTTR finding.** A single ConfigMap field (`timeout.reconciliation: 30s`) reduces median drift recovery by an order of magnitude. This is undocumented in cost-of-ownership terms and meaningfully shifts the value of self-hosted ArgoCD vs. enterprise alternatives that brand "fast sync" as a paid feature.
- **6.2 Asymmetric improvement: drift fast, git polling still slow — fixed by webhook.** Patching `timeout.reconciliation` accelerates k8s-side reconciliation but leaves the git polling cache untouched (4.3× improvement only: 132 s → 74 s). Operators expecting "30 s sync everywhere" by tuning a single knob will be surprised. Implementing a GitHub webhook (ngrok tunnel + HMAC secret in `argocd-secret`) reduced median git-push-to-pod-ready to **15 s — within 2× of the forced-sync ceiling (7 s)** and 9× faster than natural polling. The configuration cost is trivial (one ConfigMap key, one GitHub webhook). This result argues that published ArgoCD benchmarks relying on default polling materially under-represent what the platform can do in practice.
- **6.3 The 110-pod ceiling.** On laptop hardware, kubelet's `maxPods=110` default — not RAM — is the practical scale limit at this configuration. This is trivially raisable but is a useful empirical correction to the prevailing intuition that "memory is the laptop bottleneck."
- **6.4 Resource frugality of the automation layer.** n8n + alert-simulator together added < 2 % runtime overhead. The narrative that workflow automation is heavy is incorrect for self-hosted, single-tenant n8n.
- **6.5 Reasoning about cost claims.** Hardware is not free. Attributing a $500 laptop over 36 months adds ~$14/mo; the platform is $0 *recurring* but not $0 *amortized*. Engineering time (~20 h to stabilize on this configuration) is the dominant unaccounted cost.
- **6.6 Generalizability.** Single-node single-laptop deployment will not survive enterprise SLAs. The architecture is appropriate for: solo developers, hackathons, demo / training labs, and disaster-recovery cold standby. Not appropriate for: production multi-team services, regulated workloads, or HA targets.

---

## 7. Limitations

**Goal:** ½ page. Be honest. Reviewers reward this.

- **L1.** Single host, single hardware profile (8 GB / 6 vCPU on one laptop). No cross-host validation yet.
- **L2.** kindnet does not enforce NetworkPolicy (documented in §3.6). Multi-tenant *isolation* is logical (namespace), not enforced; for true isolation, swap CNI to Calico — costs ~150 Mi extra memory.
- **L3.** No persistent observability (no Prometheus/Grafana) in the minimal profile. metrics-server alone provides only point-in-time samples.
- **L4.** Webhook tunnel in the experiment uses ngrok free tier — ephemeral URL, not production-grade. Cloudflare Tunnel or self-hosted reverse proxy recommended for permanent installations.
- **L5.** Small sample sizes per experiment (n = 3–10). Findings are systems-evidence, not statistically inferential.
- **L6.** Reproducibility (timed clean install) not yet measured (deferred).

---

## 8. Future Work

- **F1.** ~~Webhook-driven ArgoCD sync~~ **DONE** (see §5.3, script `04c`). Future: replace ngrok with a stable Cloudflare Tunnel for always-on operation.
- **F2.** Multi-host cluster (kind multi-node or k3s on a Raspberry Pi) — test horizontal scaling.
- **F3.** Replace kindnet with Calico — enable real NetworkPolicy enforcement; re-measure tenant isolation under attack workload.
- **F4.** Add Prometheus + Grafana in a "medium" profile and measure overhead delta.
- **F5.** Reproducibility study — three fresh installs on three machines, timed.
- **F6.** Formal security posture scan (e.g., kubescape, trivy) — current scope is ops, not sec.

---

## 9. Conclusion

**Goal:** ~⅓ page.

A reproducible, zero-cost DevSecOps platform was built and quantitatively characterized on an 8 GB laptop. Across eight controlled experiments, the platform demonstrated GitOps continuous delivery (~7 s pipeline lead time once triggered), 39× faster drift recovery via one ConfigMap change, sub-second alert latency in steady state, stable resource consumption (~2 GB) over an hour, and a real ceiling at ~110 pods set by Kubernetes' own kubelet defaults rather than host memory. At matched capability, equivalent commercial SaaS would cost ~₹1.65 L/year. The work shows, with measurements, that small teams can reach a meaningful slice of the DevSecOps maturity curve at no recurring cost — at the price of operator effort, single-node fragility, and self-hosted maintenance burden.

---

## 10. Acknowledgments / Funding (if applicable)

---

## 11. References

(Build incrementally. Suggested seeds:)

- ArgoCD documentation, *Reconciliation*, https://argo-cd.readthedocs.io/.
- kind documentation, https://kind.sigs.k8s.io/.
- Beyer et al., *Site Reliability Engineering*, O'Reilly.
- Weaveworks, *Guide to GitOps*, 2017.
- AWS EKS Pricing, https://aws.amazon.com/eks/pricing/.
- Datadog Pricing, https://www.datadoghq.com/pricing/.
- n8n Pricing, https://n8n.io/pricing/.
- Akuity Platform Pricing, https://akuity.io/pricing.
- CNCF, *State of FinOps* report (most recent year).
- Kubernetes documentation, *kubelet `maxPods`*, https://kubernetes.io/docs/reference/.
- Linode Kubernetes Engine pricing, https://www.linode.com/pricing/kubernetes/.

---

## Appendices (suggested)

- **A. Reproducibility checklist.** All commands needed to recreate the platform from a fresh WSL distro.
- **B. CSV schemas.** Column-by-column descriptions for each `research/data/*.csv`.
- **C. Manifest listings.** Selected key YAMLs (kind-cluster, n8n deployment, alert-simulator CronJob, tenant deployment) inline.
- **D. Full cost table** (`cost-table.md` reproduced verbatim).

---

## Evidence-to-section map (cheat sheet for writing)

| Section | Use these artifacts |
|---|---|
| Abstract | `findings.md` headline numbers |
| §1 Introduction | `cost-table.md`, brief MTTR + ceiling teaser |
| §3 Architecture | `kind-cluster-minimal.yaml`, `scripts/setup-minimal.sh`, `k8s/**`, `n8n-workflows/incident-triage.json`, `windows-setup/.wslconfig` |
| §4 Methodology | `research/scripts/01–07*.sh` |
| §5.1 | `data/timeseries.csv`, **Fig 3** |
| §5.2 | `data/mttr-pod.csv`, `data/mttr-drift-slowpoll.csv`, `data/mttr-drift-fastpoll.csv`, **Fig 1** |
| §5.3 | `data/gitops-leadtime.csv`, `data/gitops-leadtime-natural.csv`, **Fig 2** |
| §5.4 | `data/timeseries.csv`, `data/timeseries-docker.csv`, **Fig 3** |
| §5.5 | `data/scale-test-small.csv`, `data/scale-test-aggressive.csv`, **Fig 4** |
| §5.6 | `data/alert-latency.csv`, **Fig 5** |
| §5.7 | `data/cost-table.md`, **Fig 6** |
| §6 Discussion | `findings.md` (entire) |
| §7 Limitations | `progress.md` known issues + `findings.md` caveats |

---

## Writing schedule (suggested)

| Day | Target | Pages drafted |
|---|---|---|
| 1 | §3 Architecture + diagram | ~2 |
| 2 | §4 Methodology + tables | ~1.5 |
| 3 | §5 Results — 3 sub-experiments | ~1.5 |
| 4 | §5 Results — remaining 4 + §5.7 | ~1.5 |
| 5 | §1 Intro + §2 Related Work | ~2 |
| 6 | §6 Discussion + §7 Limitations + §8 Future Work + §9 Conclusion | ~2 |
| 7 | Abstract, References, Appendices, polish | — |
| 8 | Internal review pass | — |

**Realistic calendar at 1–2 hr/evening: 10–14 days from blank page to polished draft.**

