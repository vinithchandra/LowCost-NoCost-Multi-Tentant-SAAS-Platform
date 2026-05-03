# GitHub webhook → ArgoCD setup (reference)

Enables sub-30-s GitOps sync by having GitHub push `push` events directly
into `argocd-server`, bypassing the default polling caches.

**Measured result:** median git-push → pod-ready = **15 s** (vs 132 s on
default polling). See `research/findings.md` §"GitOps lead time — webhook".

## Prerequisites

- ArgoCD installed in namespace `argocd`, deployment `argocd-server` exposed.
- Public tunnel capability (ngrok free tier used here; Cloudflare Tunnel
  recommended for permanent installs).
- GitHub repo admin rights (to add webhooks).

## One-time setup

```bash
# 1. Install ngrok + register auth token
curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
  | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
  | sudo tee /etc/apt/sources.list.d/ngrok.list
sudo apt update -qq && sudo apt install -y ngrok
ngrok config add-authtoken <YOUR_TOKEN>       # from dashboard.ngrok.com

# 2. Make argocd-server serve plain HTTP (simpler than TLS through ngrok)
kubectl -n argocd patch deployment argocd-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'
kubectl -n argocd rollout status deployment argocd-server --timeout=180s

# 3. Install a webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Secret (save for GitHub UI): $WEBHOOK_SECRET"
kubectl -n argocd patch secret argocd-secret --type=merge \
  -p "{\"stringData\":{\"webhook.github.secret\":\"$WEBHOOK_SECRET\"}}"
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=180s
```

## Per-session (tunnel is ephemeral on free tier)

```bash
# 4. Port-forward argocd-server :80 → localhost:8888
pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
sleep 2
nohup kubectl -n argocd port-forward svc/argocd-server 8888:80 --address=127.0.0.1 \
  > /tmp/argo-pf.log 2>&1 &

# 5. Start ngrok tunnel
pkill ngrok 2>/dev/null || true
sleep 2
nohup ngrok http 8888 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 6

# 6. Get the public URL
PUBLIC_URL=$(curl -s http://127.0.0.1:4040/api/tunnels \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['tunnels'][0]['public_url'])")
echo "Webhook endpoint: $PUBLIC_URL/api/webhook"
```

## GitHub UI configuration (once)

Go to:
`https://github.com/<OWNER>/<REPO>/settings/hooks/new`

Fill in:

| Field | Value |
|---|---|
| Payload URL | `<PUBLIC_URL>/api/webhook` |
| Content type | `application/json` (MUST change) |
| Secret | value of `$WEBHOOK_SECRET` |
| SSL verification | enabled |
| Which events | Just the push event |
| Active | ✅ |

A successful ping webhook appears in `kubectl logs` as:
```
level=info msg="Ignoring webhook event"   # ping is ignored, push is acted on
```

## Verify

```bash
# Push a trivial commit
git commit --allow-empty -m "test webhook" && git push

# Within ~15 s you should see ArgoCD refresh the target Application
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server --tail=50 \
  | grep -iE "webhook|refreshing"
```

## Tear-down (ephemeral session)

```bash
pkill ngrok
pkill -f "port-forward svc/argocd-server"
```

The webhook configuration in GitHub remains; deliveries will fail (expected)
until the tunnel is re-established with a new public URL. Update the Payload
URL in GitHub if the ngrok subdomain changes.

## Limitations

- **Ngrok free tier** assigns a new subdomain each session unless you
  purchase a reserved domain. For production, use Cloudflare Tunnel
  (free, stable domain) or expose the cluster via a real ingress.
- **`--insecure` on argocd-server** — we terminate TLS at ngrok. If you
  front the cluster with its own ingress + valid cert, drop the
  `--insecure` flag and use HTTPS end-to-end.
- **HMAC secret is a shared credential** — treat it like a password; store
  in a secret manager for production.
