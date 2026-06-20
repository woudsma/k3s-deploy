# k3s-deploy

Making it dead-simple to deploy apps on your own [K3s](https://k3s.io/) cluster.

Infrastructure configuration for a self-hosted Kubernetes cluster running on a Hetzner VPS (Ubuntu) with K3s.

## What's in this repo

| Directory | Description |
|---|---|
| `charts/app/` | Generic Helm chart for all app types (websites, APIs, databases) |
| `cert-manager/` | ClusterIssuer for automatic Let's Encrypt SSL via cert-manager |
| `registry/` | Private Docker registry (in-cluster) with htpasswd auth |
| `deploy/` | Git-push deploy setup — Dokku-like `git push deploy main` experience |
| `monitoring/` | Headlamp dashboard + Trivy vulnerability scanning |
| `examples/` | Example `helm-values.yaml` files for common app types |

## Stack

- **K3s** — lightweight, CNCF-certified Kubernetes distribution
- **Traefik** — ingress controller (K3s default)
- **cert-manager** — automatic TLS certificates from Let's Encrypt
- **Helm** — single generic chart covers all app types
- **Private registry** — in-cluster container image storage
- **Kaniko** — in-cluster Docker image builds (no Docker daemon required)

## How deployments work

A single Helm chart (`charts/app/`) provides templates for Deployment, Service, Ingress, and PVC. Each app only needs a `helm-values.yaml` to override the defaults — no raw Kubernetes manifests required.

```
my-app/
├── Dockerfile
└── helm-values.yaml    # only K8s-related file needed
```

A minimal `helm-values.yaml` for a website is ~4 lines:

```yaml
name: my-website
ingress:
  hosts:
    - my-website.mysite.com
```

Everything else (port 80, health probe, TLS, resource limits) comes from chart defaults. See `charts/app/values.yaml` for all available options.

### Deploying

First deploy — just push, the hook runs `helm upgrade --install` and creates all resources:

```bash
git remote add deploy deploy@<server-ip>:my-app
git push deploy main
```

Two ways to deploy updates:

1. **Git push** — `git push deploy main` builds on the server, streams logs back (Dokku-like)
2. **GitHub Actions** — CI/CD builds image, pushes to registry, deploys via Helm

See [CLAUDE.md](CLAUDE.md) for full setup instructions, commands, and architecture decisions.

## Initial server setup

After creating a fresh Hetzner VPS with Ubuntu, the guided `setup.sh` script brings the whole cluster up.

**First, point your domain at the server.** Add a DNS A record for `*.<domain>` pointing to the server's IP. The cluster issues wildcard TLS for your subdomains, so this must resolve before setup runs.

Then copy this repo to the server and run `setup.sh`. It prompts for your domain and registry credentials, replaces the `mysite.com` placeholder repo-wide, and installs everything: K3s, security hardening, cert-manager + Let's Encrypt, the private registry and its pull/push secrets, the git-push deploy system, and the monitoring stack.

```bash
rsync -a --exclude='.git' . root@<server-ip>:/tmp/k3s-deploy
ssh root@<server-ip>
bash /tmp/k3s-deploy/setup.sh
```

When it finishes, the script prints the remaining manual steps — including copying the kubeconfig from `/etc/rancher/k3s/k3s.yaml` to your local `~/.kube/config` (replace `127.0.0.1` with the server IP) for remote `kubectl` access.

See [CLAUDE.md](CLAUDE.md) for a step-by-step breakdown of everything `setup.sh` does.

## Monitoring

### Headlamp (cluster dashboard)

A lightweight web dashboard at `headlamp.<domain>` for browsing pods, viewing logs, exec-ing into containers, and checking resource status.

Deployed automatically by `setup.sh`. To generate a login token:

```bash
kubectl create token headlamp -n headlamp --duration=8760h
```

### Trivy (vulnerability scanning)

Daily CronJob that scans all running images for HIGH/CRITICAL vulnerabilities. View results:

```bash
kubectl logs -l app=trivy-scan --tail=100
```

## Examples

The [`examples/`](examples/) directory has ready-to-use `helm-values.yaml` files for common app types — websites, APIs, WebSocket apps, databases, multi-domain setups, per-environment configs, and GitHub Actions workflows.
