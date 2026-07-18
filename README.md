# k3s-deploy

Making it dead-simple to deploy apps on your own [K3s](https://k3s.io/) cluster.  
Tested on Hetzner CX23/CX33 Ubuntu VPS.

## Stack

- **K3s** — lightweight, CNCF-certified Kubernetes distribution
- **Traefik** — ingress controller (K3s default)
- **cert-manager** — automatic TLS certificates from Let's Encrypt
- **Helm** — single generic chart covers all app types
- **Private registry** — in-cluster container image storage
- **Kaniko** — in-cluster Docker image builds (no Docker daemon required)

## Installation - initial server setup

After creating a fresh Hetzner VPS with Ubuntu, the guided `setup.sh` script brings the whole cluster up.

**First, point your domain at the server.** Add a wildcard DNS A record for `*.<domain>` pointing to the server's IP, so any subdomain you deploy resolves without adding a new record each time. cert-manager then issues (and auto-renews) an individual TLS certificate per subdomain via the HTTP-01 challenge, so this must resolve before setup runs.

Then SSH into the fresh server (as `root`) and run the one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/woudsma/k3s-deploy/main/install.sh | sh
```

This installs git/curl, clones the repo to `/opt/k3s-deploy`, and launches `setup.sh`.

<details>
<summary>Prefer to clone it yourself?</summary>

```bash
cd k3s-deploy
rsync -a --exclude='.git' . root@<server-ip>:/tmp/k3s-deploy
ssh root@<server-ip>
bash /tmp/k3s-deploy/setup.sh
```
</details>

`setup.sh` prompts for your domain and registry credentials, replaces the `mysite.com` placeholder repo-wide, and installs everything: K3s, security hardening, cert-manager + Let's Encrypt, the private registry and its pull/push secrets, the git-push deploy system, and (optionally) the Headlamp dashboard. Optional extras — security hardening, swap, Headlamp, zsh, and the login banner — are individual yes/no prompts.

When it finishes, the script prints the remaining manual steps — including copying the kubeconfig from `/etc/rancher/k3s/k3s.yaml` to your local `~/.kube/config` (replace `127.0.0.1` with the server IP) for remote `kubectl` access.

See [CLAUDE.md](CLAUDE.md#cluster-setup-commands) for a step-by-step breakdown of everything `setup.sh` does.

## How deployments work

![git push](./deploy.svg)

Each app only needs a `helm-values.yaml` to override the helm defaults (seen in `charts/app/`) — no raw Kubernetes manifests required. 

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

Monorepos and multi-environment repos can push to several app names from one repository — an optional `.deploy/<app-name>.conf` per target selects the build context, Helm values file, build args and allowed ref. See [`examples/monorepo/`](examples/monorepo/).

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

### Deploying with an AI agent

[AGENTS.md](AGENTS.md) is a self-contained guide covering everything above — paste its raw URL into a prompt in any project and the agent knows how to deploy that app to your cluster without reading this repo:

```
https://raw.githubusercontent.com/woudsma/k3s-deploy/main/AGENTS.md
```

## Monitoring

### Headlamp (cluster dashboard)

A lightweight web dashboard at `headlamp.<domain>` for browsing pods, viewing logs, exec-ing into containers, and checking resource status.

Optional — `setup.sh` asks whether to install it. To deploy it later, or to generate a login token:

```bash
kubectl apply -f monitoring/headlamp.yaml   # if you skipped it during setup
kubectl create token headlamp -n headlamp --duration=8760h
```

### Trivy Operator (vulnerability scanning)

Continuously scans every workload's image (any language — Node, Python, Go, …) for
HIGH/CRITICAL vulnerabilities and publishes the results as `VulnerabilityReport`
resources. View them:

```bash
# One report per workload, with critical/high counts
kubectl get vulnerabilityreports -n default

# Summary table for all apps at once (critical/high per workload)
kubectl get vulnerabilityreports -n default -o custom-columns=\
'WORKLOAD:.metadata.labels.trivy-operator\.resource\.name,IMAGE:.report.artifact.repository,'\
'CRITICAL:.report.summary.criticalCount,HIGH:.report.summary.highCount'

# Full CVE detail for a single report
kubectl describe vulnerabilityreport -n default <name>
```

Reports also show up in the Headlamp dashboard.

## Examples

The [`examples/`](examples/) directory has ready-to-use `helm-values.yaml` files for common app types — websites, APIs, WebSocket apps, databases, multi-domain setups, per-environment configs, and GitHub Actions workflows.

## What's in this repo

| Directory | Description |
|---|---|
| `charts/app/` | Generic Helm chart for all app types (websites, APIs, databases) |
| `cert-manager/` | ClusterIssuer for automatic Let's Encrypt SSL via cert-manager |
| `registry/` | Private Docker registry (in-cluster) with htpasswd auth |
| `deploy/` | Git-push deploy setup — Dokku-like `git push deploy main` experience |
| `monitoring/` | Headlamp dashboard (Trivy Operator is installed from upstream by `setup.sh`) |
| `examples/` | Example `helm-values.yaml` files for common app types |
| `test/` | End-to-end harness: runs `setup.sh` + a real git-push deploy in a throwaway container and asserts the cluster came up |