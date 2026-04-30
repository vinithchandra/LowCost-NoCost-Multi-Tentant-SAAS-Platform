# n8n Workflow — Incident Triage

Build this in the n8n UI at http://localhost:30002 after Step 8.

| # | Node | Configuration | Purpose |
|---|------|---------------|---------|
| 1 | Webhook              | `POST /incident-alert`                                | Receives Alertmanager payloads |
| 2 | HTTP Request         | `GET http://kube-prometheus-prometheus.monitoring:9090/api/v1/query?query=rate(http_requests_total{status=~"5.."}[5m])` | Query current error rate |
| 3 | IF                   | `{{$json.data.result[0].value[1]}} > 0.01`            | Decide if real incident |
| 4 (true)  | HTTP Request | `POST <SLACK_WEBHOOK_URL>` body `{"text":"Incident in {{$json.alert}}"}` | Notify Slack |
| 5 (false) | NoOp         | —                                                     | Ignore transient spikes |

## Wire-up
1. Open n8n -> "+ New Workflow"
2. Add a `Webhook` node, set Method=POST, Path=`incident-alert`, Activate.
3. Add the `HTTP Request` node querying Prometheus (URL above).
4. Add an `IF` node with the comparison.
5. On true branch -> `HTTP Request` POST to your Slack webhook.
6. Save and Activate.

The webhook URL inside the cluster will be:
`http://n8n.platform-tools.svc.cluster.local:5678/webhook/incident-alert`
