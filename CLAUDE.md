# K8s Cluster — Context & Decisions

## Checklist for Adding New Components

When adding a new component/service to the cluster:

1. Create the manifest in the appropriate directory
2. Use `mysite.com` as the domain placeholder — `setup.sh` replaces it repo-wide automatically
3. Add the deploy step to `setup.sh`
4. Update the repo structure tree in this file
5. Update `README.md` if it affects the user-facing docs

## Shell scripts

**Always run `shellcheck` on any shell script you change and resolve the findings**
(fix them, or suppress with a `# shellcheck disable=SCxxxx` line plus a comment saying
why) before considering the change done. Intentional patterns — e.g. the deliberate
word-splitting in `deploy/pre-receive-hook` or the mtime-ordered `ls` in
`deploy/cleanup-old-images.sh` — must carry such a justified disable directive so the
scripts stay shellcheck-clean.

## Overview

Self-hosted Kubernetes cluster on a Hetzner VPS using K3s. The cluster runs personal websites, APIs, and databases with automatic SSL, a private container registry, and a build service for Dokku-like deployments.

**Domain:** `*.mysite.com`
**GitHub user:** `username`

---

## Architecture Decisions

### Kubernetes distribution: K3s

- CNCF-certified, ~95% compatible with full Kubernetes
- ~512 MB RAM overhead — lightest option for single-node VPS
- Uses containerd (same runtime Docker uses under the hood)
- Ships with Traefik as the default ingress controller
- Uses SQLite instead of etcd for single-node setups

### Server: Hetzner

| Phase | Server | Specs | Price |
|---|---|---|---|
| Testing | CX22 | 2 vCPU, 4 GB RAM, 40 GB SSD | €3.99/mo |
| Production | CX32 | 4 vCPU, 8 GB RAM, 80 GB SSD | €7.49/mo |

### Ingress & SSL: Traefik + cert-manager + Let's Encrypt

- Traefik is the K3s default ingress controller
- cert-manager handles automatic certificate provisioning and renewal
- HTTP-01 challenge solver (via Traefik) for individual subdomain certs
- DNS-01 challenge (via Cloudflare) needed for wildcard certs (`*.mysite.com`)
- ClusterIssuer `letsencrypt-prod` is used cluster-wide

### Container registry: Private in-cluster registry

- Runs the `registry:2` image in a `registry` namespace
- Exposed at `registry.mysite.com` with SSL
- Secured with htpasswd basic auth
- 20Gi PersistentVolumeClaim for storage
- No dependence on Docker Hub or GHCR

### Build system: Kaniko via git-push deploys

- A `deploy` user on the server accepts git pushes over SSH
- Repos are auto-created on first push (no manual setup per app)
- A `pre-receive` hook archives the code, creates a Kaniko Job with a `hostPath` volume, streams build logs back over SSH, and rolls out the deployment
- Works without GitHub — code goes directly from local to server
- After a successful rollout the hook runs `cleanup-old-images.sh` (via a narrow `deploy` sudo grant) to prune that app's stale per-commit images — keeps the running tag + `latest` on the node, and the 5 newest tags + `latest` in the registry, then runs registry GC. Without this, every push leaves an orphaned image and the disk slowly fills.

### Templating: Helm

- A single generic Helm chart (`charts/app/`) covers all app types (websites, APIs, databases)
- The chart lives in this repo and is copied to the server at `/opt/helm-charts/app/`
- Each app repo only needs a `helm-values.yaml` — no raw Kubernetes manifests
- On push, the pre-receive hook runs `helm upgrade --install` with the project's values file
- Backward compatible: apps with a `k8s/` directory (no values file) still deploy via `kubectl apply`
- See `charts/app/values.yaml` for all available options and defaults

---

## Repo Structure

```
k3s-deploy/
├── cert-manager/
│   └── cluster-issuer.yaml # Let's Encrypt ClusterIssuer (letsencrypt-prod)
├── charts/
│   └── app/                # Generic Helm chart for all app types
│       ├── Chart.yaml
│       ├── values.yaml     # Default values (port 80, httpGet probe, etc.)
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── ingress.yaml
│           └── pvc.yaml
├── deploy/
│   ├── setup-deploy.sh        # Run on server to set up git-push deploys + Helm
│   ├── deploy-shell           # Custom shell for the deploy user
│   ├── cleanup-old-images.sh  # Prunes stale node + registry images post-deploy
│   └── pre-receive-hook       # Shared hook: Kaniko build + Helm deploy + prune
├── examples/               # Example helm-values.yaml files per app type
├── monitoring/
│   ├── headlamp.yaml       # Lightweight K8s dashboard (headlamp.mysite.com)
│   ├── trivy-scan.yaml     # Daily image vulnerability scanner (CronJob)
│   └── extra/              # Optional monitoring add-ons (see extra/README.md)
│       ├── README.md
│       ├── kube-prometheus-stack/
│       │   └── values.yaml # Lightweight Prometheus + Grafana (own namespace)
│       └── uptime-kuma/
│           ├── helm-values.yaml
│           ├── add_monitors.py
│           ├── setup_status_page.py
│           ├── kuma_common.py
│           └── .env.example
├── registry/
│   └── registry.yaml       # Private registry: Deployment, PVC, Service, Ingress
├── test/
│   ├── Dockerfile          # Systemd Ubuntu image mimicking a fresh Hetzner VPS
│   ├── run.sh              # Runs setup.sh + a sample deploy in a container + asserts
│   └── hello-world/        # Sample static app pushed by the deploy test
│       ├── Dockerfile
│       ├── index.html
│       └── helm-values.yaml
```

---

## Testing a fresh install locally

`test/run.sh` runs the real `setup.sh` end-to-end against a throwaway, systemd-enabled
Ubuntu container that stands in for a fresh Hetzner VPS, asserts the cluster came up
(node Ready, cert-manager, registry, secrets, deploy user, Helm chart, cleanup script +
sudoers, domain replacement), then does a **real `git push` deploy** of the
`test/hello-world/` static app — exercising the full pipeline (Kaniko build → push to
the private registry → Helm deploy → reachable through Traefik) with the build logs
streaming back. 16 checks total. Requires Docker running.

```bash
test/run.sh          # build base image (once), run setup.sh + sample deploy, assert
test/run.sh shell    # open a shell in the last test container to poke around
test/run.sh clean    # remove the test container + base image
```

It's reproducible and cheap to repeat: each run force-removes the previous container
and reuses the cached base image, so running it many times doesn't pile up images.

Test-environment accommodations (production code is unchanged):
- K3s can't use the overlayfs snapshotter nested in Docker, so the harness injects
  `INSTALL_K3S_EXEC=--snapshotter=native`. A real VPS uses overlayfs.
- The optional prompts (hardening/swap/zsh/motd) are answered "no" — they touch
  host-level facilities (ufw, swapon, chsh) not meaningful in a container.
- The registry has no public DNS or real cert offline, so the harness routes
  `registry.<domain>` through Traefik with TLS verification skipped: a pre-install
  `registries.yaml` (containerd) + `/etc/hosts` entry, a CoreDNS rewrite (build/pull
  pods), and `KANIKO_EXTRA_ARGS="--skip-tls-verify"` in the deploy config. The
  `registries.yaml` is written *before* K3s installs on purpose — adding it later needs
  a k3s restart, which orphans port-holding pods (Traefik/registry) and breaks the
  cluster. `KANIKO_EXTRA_ARGS` is a general hook knob (empty in prod, also useful for
  real insecure/internal registries).

---

## Cluster Setup Commands

### 1. Install K3s

```bash
ssh root@<server-ip>
curl -sfL https://get.k3s.io | sh -
kubectl get nodes
```

### 2. Configure local kubectl access

```bash
# Copy kubeconfig from server
sudo cat /etc/rancher/k3s/k3s.yaml
# Save to ~/.kube/config, replace 127.0.0.1 with server IP
```

### 3. Security hardening

```bash
# Key-only auth
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    # SSH
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS
ufw allow 6443/tcp  # K3s API (restrict to your IP)
ufw enable

# Fail2ban
apt install fail2ban -y
systemctl enable fail2ban
```

### 4. Point DNS to the server

Add a wildcard DNS A record for `*.<domain>` pointing to the server IP.

### 5. Copy this repo to the server

```bash
# From your local machine
rsync -a --exclude='.git' . root@<server-ip>:/tmp/k3s-deploy
```

### 6. Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=available deployment --all -n cert-manager --timeout=120s
kubectl apply -f /tmp/k3s-deploy/cert-manager/cluster-issuer.yaml
```

### 7. Deploy the private registry

```bash
kubectl create namespace registry

# Create auth secret (generate htpasswd first)
apt install apache2-utils -y
htpasswd -Bc registry-htpasswd username
kubectl create secret generic registry-auth \
  --from-file=htpasswd=registry-htpasswd \
  -n registry

kubectl apply -f /tmp/k3s-deploy/registry/registry.yaml
```

### 8. Create registry pull/push secrets

```bash
# For Kaniko to push images
echo '{"auths":{"registry.mysite.com":{"username":"username","password":"<PASSWORD>"}}}' > /tmp/docker-config.json
kubectl create secret generic kaniko-docker-config \
  --from-file=config.json=/tmp/docker-config.json
rm /tmp/docker-config.json

# For K3s to pull images
kubectl create secret docker-registry kaniko-registry-creds \
  --docker-server=registry.mysite.com \
  --docker-username=username \
  --docker-password=<PASSWORD>

# GitHub token for Kaniko to clone private repos
kubectl create secret generic git-credentials \
  --from-literal=token=<GITHUB_PAT>
```

### 9. Deploy Headlamp dashboard

```bash
kubectl apply -f /tmp/k3s-deploy/monitoring/headlamp.yaml

# Create a long-lived token to log in
kubectl create token headlamp -n headlamp --duration=8760h
```

Visit `headlamp.mysite.com` and paste the token to log in.

### 10. Set up git-push deploys

```bash
# Run the setup script (repo was copied in step 5)
bash /tmp/k3s-deploy/deploy/setup-deploy.sh "$(cat ~/.ssh/authorized_keys)"
```

This creates a `deploy` user, installs Helm, copies the Helm chart to `/opt/helm-charts/app/`, installs the custom shell and pre-receive hook, copies the kubeconfig, and sets up your SSH key. Repos are auto-created on first push.

---

## Deploying a New App

### Project structure convention

```
my-app/
├── Dockerfile
├── helm-values.yaml        # Only K8s-related file needed
├── src/
└── .github/
    └── workflows/
        └── deploy.yml      # (optional) CI/CD alternative
```

The `helm-values.yaml` overrides chart defaults. For a website, this is ~4 lines:

```yaml
name: my-app
ingress:
  hosts:
    - my-app.mysite.com
```

See `examples/` for values files covering websites, APIs, databases, and more.

### First deploy — just git push

The pre-receive hook runs `helm upgrade --install` with the project's `helm-values.yaml`, so the first push creates all resources and deploys.

### Three ways to deploy updates

**A. Git push (Dokku-like)** — push to the server, build logs stream back in your terminal:

```bash
# One-time: add the remote
git remote add deploy deploy@<server-ip>:my-app

# Deploy (repo is auto-created on first push)
git push deploy main
```

**B. GitHub Actions** — builds in Actions runner, pushes to private registry, deploys via Helm. Requires these repo secrets:

| Secret | Value |
|---|---|
| `KUBECONFIG` | Contents of `/etc/rancher/k3s/k3s.yaml` (with public IP) |
| `REGISTRY_USER` | `username` |
| `REGISTRY_PASS` | Registry password |

---

## Adding a Worker Node

On the master, get the token:

```bash
cat /var/lib/rancher/k3s/server/node-token
```

On the new node:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<master-ip>:6443 K3S_TOKEN=<token> sh -
```

---

## Cluster Secrets Reference

| Secret | Namespace | Purpose |
|---|---|---|
| `registry-auth` | `registry` | htpasswd for registry basic auth |
| `kaniko-docker-config` | `default` | Kaniko pushes to private registry |
| `kaniko-registry-creds` | `default` | K3s pulls images from private registry |
| `git-credentials` | `default` | Kaniko clones private GitHub repos |
| `letsencrypt-prod` | `cert-manager` | Let's Encrypt ACME account key |

---

## Useful Commands

```bash
# Check all resources
kubectl get pods,svc,ingress,certificates --all-namespaces

# Check cert status
kubectl get certificates --all-namespaces

# Watch build jobs
kubectl get jobs -l app=build

# View build logs
kubectl logs -f job/build-<app>-<sha>

# Restart a deployment
kubectl rollout restart deployment/<app>

# Check ingress
kubectl get ingress --all-namespaces

# Helm: list releases
helm list -n default

# Helm: check what's deployed for an app
helm status <app> -n default

# Helm: preview what would be applied
helm template <app> charts/app -f helm-values.yaml

# Helm: roll back to previous version
helm rollback <app> -n default

# Trivy: view latest scan results
kubectl logs -l app=trivy-scan --tail=100

# Trivy: run a scan manually
kubectl create job --from=cronjob/trivy-scan trivy-scan-manual

# Headlamp: generate a new login token
kubectl create token headlamp -n headlamp --duration=8760h
```
