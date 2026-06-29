# Extra Monitoring Components

Optional monitoring tools you can deploy alongside the core cluster. Each subfolder is self-contained — install what you need, skip the rest.

---

## Deploying

### Uptime Kuma

Lightweight uptime monitoring with a public status page. Uses the generic app Helm chart already on the server.

```bash
# Copy values to server and deploy
cat monitoring/extra/uptime-kuma/helm-values.yaml | ssh k3s 'cat > /tmp/uptime-kuma-values.yaml'
ssh k3s 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install uptime-kuma /opt/helm-charts/app -n default -f /tmp/uptime-kuma-values.yaml'
```

After deploying, use the Python helper scripts to auto-create monitors:

```bash
# One-time setup
python3 -m venv .venv && .venv/bin/pip install uptime-kuma-api

# Copy .env.example to .env.local and fill in credentials
cp monitoring/extra/uptime-kuma/.env.example monitoring/extra/uptime-kuma/.env.local

# Create a monitor for every Ingress host (idempotent)
.venv/bin/python monitoring/extra/uptime-kuma/add_monitors.py --dry-run
.venv/bin/python monitoring/extra/uptime-kuma/add_monitors.py

# Set up the public status page
.venv/bin/python monitoring/extra/uptime-kuma/setup_status_page.py
```

To remove:

```bash
ssh k3s 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm uninstall uptime-kuma -n default'
# PVC is retained — delete manually if you want to wipe data:
ssh k3s 'kubectl delete pvc uptime-kuma -n default'
```

---

### Kube Prometheus Stack

Full cluster metrics (Prometheus + Grafana + node-exporter + kube-state-metrics). Deployed into its own `monitoring` namespace so it's easy to remove cleanly.

```bash
# Add the Helm repo (once)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install
kubectl create namespace monitoring
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring/extra/kube-prometheus-stack/values.yaml \
  --set grafana.adminPassword='YOUR_PASSWORD'
```

Grafana will be available at `grafana.mysite.com`.

To remove completely:

```bash
helm uninstall kube-prometheus -n monitoring
kubectl delete namespace monitoring
# CRDs are not removed by helm uninstall — clean up manually:
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com \
  alertmanagers.monitoring.coreos.com podmonitors.monitoring.coreos.com \
  probes.monitoring.coreos.com prometheusagents.monitoring.coreos.com \
  prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com \
  scrapeconfigs.monitoring.coreos.com servicemonitors.monitoring.coreos.com \
  thanosrulers.monitoring.coreos.com
```

---

## Notes

- All files use `mysite.com` as the domain placeholder — `setup.sh` replaces it repo-wide.
- The Prometheus stack is tuned for low resource usage (60s scrape interval, 7-day retention, tight memory limits). Adjust `values.yaml` if you need more.
- Alertmanager is disabled by default; enable it in the values file when you want alerting.
