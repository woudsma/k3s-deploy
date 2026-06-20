# Examples

Helm values files for common app types on this cluster.

Each `.yaml` file is a complete example of a `helm-values.yaml` — the only Kubernetes-related file a project needs. The Helm chart (`charts/app/`) provides all the templates; these files just override the defaults.

## How it works

1. The generic Helm chart lives in `charts/app/` in this repo
2. It's copied to the server at `/opt/helm-charts/app/` during setup
3. Each app repo contains only a `helm-values.yaml` in its root
4. On `git push`, the pre-receive hook runs `helm upgrade --install` with that values file

## Examples

| File | Type | What it configures |
|---|---|---|
| `website.yaml` | Static site | Just name + hostname (~4 lines) |
| `api.yaml` | Node.js / Python API | Port 3000, health probe, env vars, bigger resources |
| `websocket.yaml` | WebSocket app | Like API + Traefik sticky session annotation |
| `multi-domain.yaml` | Multi-domain site | Two hostnames (apex + www) |
| `stateful-website.yaml` | Stateful web app | Persistent volume + secrets, Recreate strategy, custom port |
| `database.yaml` | PostgreSQL | Public image, no ingress, persistent volume, exec probe |
| `redis.yaml` | Redis | Public image, no ingress, persistent volume, exec probe |
| `environments/` | Multi-env | Per-environment values for dev, test, and prod |

## Usage

Copy an example, rename it to `helm-values.yaml`, and adjust the values:

```bash
cp examples/website.yaml ~/my-project/helm-values.yaml
# Edit name and hostname, then deploy:
git push deploy main
```

## Chart defaults

See `charts/app/values.yaml` for all available options and their defaults. A website only needs to set `name` and `ingress.hosts` — everything else (port 80, httpGet `/` probe, small resources, TLS) comes from defaults.

## Environments

See `environments/` for per-environment Helm values files (dev, test, prod). Each environment gets its own namespace, hostname, resource limits, and replicas. The `github-actions/deploy-environments.yaml` workflow shows how to wire this into CI/CD with staged deployments.

## GitHub Actions

See `github-actions/` for CI workflow examples that use `helm upgrade --install` instead of `kubectl apply`.
