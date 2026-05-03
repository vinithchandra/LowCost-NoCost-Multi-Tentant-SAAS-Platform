"""Generate paper-ready PNG figures from research CSVs.

Usage:
  cd research
  python3 plots.py

Outputs ./plots/*.png
"""
from __future__ import annotations

import csv
import os
from pathlib import Path
from statistics import mean, median

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = Path(__file__).parent
DATA = HERE / "data"
OUT = HERE / "plots"
OUT.mkdir(exist_ok=True)

plt.rcParams.update({
    "figure.figsize": (8, 5),
    "figure.dpi": 130,
    "font.size": 11,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
    "axes.spines.top": False,
    "axes.spines.right": False,
    "savefig.bbox": "tight",
})


def read_csv(path: Path) -> list[dict]:
    with path.open() as f:
        return list(csv.DictReader(f))


# ---------- Figure 1: MTTR comparison (drift slow vs fast, plus pod-kill) ----------
def fig_mttr_comparison() -> None:
    slow = [float(r["mttr_seconds"]) for r in read_csv(DATA / "mttr-drift-slowpoll.csv")]
    fast = [float(r["mttr_seconds"]) for r in read_csv(DATA / "mttr-drift-fastpoll.csv")]
    pod = [float(r["mttr_seconds"]) for r in read_csv(DATA / "mttr-pod.csv")]

    groups = ["Pod kill\n(k8s only)", "Drift heal\n(180 s poll)", "Drift heal\n(30 s poll)"]
    data = [pod, slow, fast]
    means = [mean(d) for d in data]
    medians = [median(d) for d in data]

    fig, ax = plt.subplots()
    x = range(len(groups))
    bp = ax.boxplot(data, positions=list(x), widths=0.5, showmeans=True,
                    meanprops=dict(marker="D", markerfacecolor="white",
                                   markeredgecolor="black", markersize=7),
                    patch_artist=True,
                    boxprops=dict(facecolor="#9dc6e8", alpha=0.7))
    ax.set_xticks(list(x))
    ax.set_xticklabels(groups)
    ax.set_ylabel("Recovery time (seconds, log scale)")
    ax.set_yscale("log")
    ax.set_title("Self-healing MTTR — pod kill vs. config drift")

    # annotate medians
    for i, m in enumerate(medians):
        ax.annotate(f"med={m:.1f}s", (i, m), textcoords="offset points",
                    xytext=(12, 0), fontsize=9)

    ax.text(0.02, 0.97,
            f"Fast-poll median {medians[2]:.1f}s vs. slow-poll {medians[1]:.1f}s "
            f"≈ {medians[1]/medians[2]:.0f}× improvement",
            transform=ax.transAxes, va="top", fontsize=9,
            bbox=dict(boxstyle="round", facecolor="#fff3bf", alpha=0.8))

    fig.savefig(OUT / "fig1_mttr_comparison.png")
    plt.close(fig)


# ---------- Figure 2: GitOps lead time ----------
def fig_gitops_leadtime() -> None:
    forced = [float(r["leadtime_seconds_pod_ready"])
              for r in read_csv(DATA / "gitops-leadtime.csv")]
    natural = [float(r["leadtime_seconds_pod_ready"])
               for r in read_csv(DATA / "gitops-leadtime-natural.csv")]

    fig, ax = plt.subplots()
    data = [forced, natural]
    labels = ["Forced sync\n(`argocd app sync`)",
              "Natural sync\n(30 s poll)"]
    ax.boxplot(data, positions=[0, 1], widths=0.5, showmeans=True,
               meanprops=dict(marker="D", markerfacecolor="white",
                              markeredgecolor="black", markersize=7),
               patch_artist=True,
               boxprops=dict(facecolor="#b2e2b2", alpha=0.7))
    ax.set_xticks([0, 1])
    ax.set_xticklabels(labels)
    ax.set_ylabel("git push → pod ready (seconds)")
    ax.set_title("GitOps lead time — triggered vs. poll-driven")
    m1, m2 = median(forced), median(natural)
    ax.annotate(f"median {m1:.1f}s", (0, m1), xytext=(12, 0),
                textcoords="offset points", fontsize=9)
    ax.annotate(f"median {m2:.1f}s", (1, m2), xytext=(12, 0),
                textcoords="offset points", fontsize=9)
    fig.savefig(OUT / "fig2_gitops_leadtime.png")
    plt.close(fig)


# ---------- Figure 3: 60-min time-series of node resources ----------
def fig_timeseries() -> None:
    rows = [r for r in read_csv(DATA / "timeseries.csv") if r["scope"] == "node"]
    # Parse timestamps as relative seconds from first sample
    from datetime import datetime
    t0 = datetime.fromisoformat(rows[0]["timestamp"])
    for r in rows:
        r["t_sec"] = (datetime.fromisoformat(r["timestamp"]) - t0).total_seconds()

    idle = [(r["t_sec"], int(r["cpu_m"]), int(r["mem_mi"]))
            for r in rows if r["phase"] == "idle"]
    load = [(r["t_sec"], int(r["cpu_m"]), int(r["mem_mi"]))
            for r in rows if r["phase"] == "load"]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 6.5), sharex=True)

    if idle:
        t, cpu, mem = zip(*idle)
        ax1.plot(t, cpu, color="#3182bd", label="idle", linewidth=1.2)
        ax2.plot(t, mem, color="#3182bd", label="idle", linewidth=1.2)
    if load:
        t, cpu, mem = zip(*load)
        ax1.plot(t, cpu, color="#e6550d", label="load (simulator on)", linewidth=1.2)
        ax2.plot(t, mem, color="#e6550d", label="load (simulator on)", linewidth=1.2)

    # phase boundary
    if idle and load:
        ax1.axvline(load[0][0], color="gray", linestyle=":", alpha=0.7)
        ax2.axvline(load[0][0], color="gray", linestyle=":", alpha=0.7)

    ax1.set_ylabel("Node CPU (millicores)")
    ax1.set_title("60-min resource time-series (30 min idle + 30 min under load)")
    ax1.legend(loc="upper right")

    ax2.set_ylabel("Node memory (MiB)")
    ax2.set_xlabel("Time (seconds since start)")
    ax2.legend(loc="lower right")

    fig.savefig(OUT / "fig3_timeseries.png")
    plt.close(fig)


# ---------- Figure 4: Scale ceiling ----------
def fig_scale_ceiling() -> None:
    path = DATA / "scale-test-aggressive.csv"
    rows = read_csv(path)

    pods = [int(r["total_pods"]) for r in rows]
    mem = [int(r["node_mem_mi"]) if r["node_mem_mi"] else None for r in rows]
    status = [r["result"] for r in rows]

    fig, ax = plt.subplots()
    # Filter out None mem values
    good = [(p, m) for p, m, s in zip(pods, mem, status) if m is not None and s == "ok"]
    bad = [(p, m) for p, m, s in zip(pods, mem, status) if m is not None and s == "fail"]

    if good:
        p, m = zip(*good)
        ax.plot(p, m, "o-", color="#31a354", label="Ready", markersize=7)
    if bad:
        p, m = zip(*bad)
        ax.plot(p, m, "X", color="#e6550d", markersize=14, label="Failed to schedule")

    ax.axhline(2117, color="gray", linestyle=":", alpha=0.7, label="Baseline (2117 MiB)")
    ax.axhline(5120, color="red", linestyle="--", alpha=0.6,
               label="WSL2 cap (5120 MiB)")

    ax.set_xlabel("Tenant pods added")
    ax.set_ylabel("Node memory (MiB)")
    ax.set_title("Scale-ceiling test — memory vs. pod count")
    ax.legend(loc="lower right", fontsize=9)

    ax.text(0.02, 0.97,
            "Ceiling hit at ≈ 107 total pods\n"
            "(kubelet maxPods=110 default)\n"
            "— memory, CPU had ample headroom.",
            transform=ax.transAxes, va="top", fontsize=9,
            bbox=dict(boxstyle="round", facecolor="#fff3bf", alpha=0.8))

    fig.savefig(OUT / "fig4_scale_ceiling.png")
    plt.close(fig)


# ---------- Figure 5: Alert-pipeline latency ----------
def fig_alert_latency() -> None:
    rows = read_csv(DATA / "alert-latency.csv")
    runs = [int(r["run"]) for r in rows]
    ms = [int(r["latency_ms"]) for r in rows]

    fig, ax = plt.subplots()
    ax.bar(runs, ms, color=["#e6550d" if m > 2000 else "#3182bd" for m in ms])
    ax.set_xlabel("Run #")
    ax.set_ylabel("End-to-end latency (ms)")
    ax.set_title("n8n alert-pipeline latency (client → webhook → sink → response)")

    warm = [m for m in ms[1:]]
    ax.axhline(median(warm), color="green", linestyle=":",
               label=f"warm-run median {median(warm):.0f} ms")
    ax.legend(loc="upper right")
    ax.text(1, ms[0] + 200, "cold start", fontsize=9, color="#e6550d")

    fig.savefig(OUT / "fig5_alert_latency.png")
    plt.close(fig)


# ---------- Figure 6: Cost comparison ----------
def fig_cost() -> None:
    labels = ["This platform\n(self-hosted)",
              "Budget cloud\n(Linode LKE + OSS)",
              "Enterprise SaaS\n(EKS + Datadog + ...)"]
    monthly = [0, 24, 166]
    colors = ["#31a354", "#fdae6b", "#e6550d"]

    fig, ax = plt.subplots()
    bars = ax.bar(labels, monthly, color=colors, edgecolor="black", linewidth=0.5)
    ax.set_ylabel("Monthly cost (USD)")
    ax.set_title("Monthly running cost at matched capability (2025 list pricing)")

    for bar, v in zip(bars, monthly):
        ax.annotate(f"${v}", (bar.get_x() + bar.get_width() / 2, v),
                    ha="center", va="bottom", fontsize=11, fontweight="bold")

    ax.text(0.02, 0.97,
            "Annual savings vs. enterprise SaaS:\n"
            "~$1 990 / year ≈ ₹1.65 lakh / year",
            transform=ax.transAxes, va="top", fontsize=9,
            bbox=dict(boxstyle="round", facecolor="#fff3bf", alpha=0.8))

    fig.savefig(OUT / "fig6_cost.png")
    plt.close(fig)


def main() -> None:
    fns = [fig_mttr_comparison, fig_gitops_leadtime, fig_timeseries,
           fig_scale_ceiling, fig_alert_latency, fig_cost]
    for f in fns:
        try:
            f()
            print(f"[ok]  {f.__name__}")
        except Exception as exc:  # noqa: BLE001
            print(f"[err] {f.__name__}: {exc}")

    print(f"\nWrote to {OUT}/")
    for p in sorted(OUT.glob("*.png")):
        print(f"  {p.name}  ({p.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
