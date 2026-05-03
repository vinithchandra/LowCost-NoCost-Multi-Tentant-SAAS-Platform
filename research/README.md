# Research data collection

All scripts in `scripts/`. Output CSVs in `data/`. Narrative & summary in `findings.md`.

## Run order

```bash
cd ~/devops-platform/research
bash scripts/01-baseline.sh
bash scripts/02-mttr-pod.sh
bash scripts/03-mttr-drift.sh
bash scripts/04-gitops-leadtime.sh   # needs git push perms cached
bash scripts/05-alert-latency.sh
bash scripts/06-timeseries.sh        # long: 60 minute sampler
bash scripts/07-scale-test.sh        # long: pushes cluster to limits
```

Each script appends to its CSV; safe to re-run.

## CSV schemas

| File | Columns |
|---|---|
| `baseline.csv` | timestamp, scope, name, cpu_m, mem_mi |
| `mttr-pod.csv` | run, timestamp, victim_pod, t_kill, t_recovered, mttr_seconds |
| `mttr-drift.csv` | run, timestamp, action, t_drift, t_revert, mttr_seconds, observed_replicas_before, observed_replicas_after |
| `gitops-leadtime.csv` | run, commit_sha, t_push, t_synced, t_pod_ready, leadtime_seconds |
| `alert-latency.csv` | run, t_curl, t_received_at_sink, latency_ms, severity |
| `timeseries.csv` | timestamp, scope, name, cpu_m, mem_mi |
| `scale-test.csv` | tenant_count, replicas_per_tenant, total_pods, ready_pods, control_plane_cpu_pct, control_plane_mem_pct, notes |
