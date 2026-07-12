# Environments

Per-environment Helm values files for deploying the same app to dev, test, and prod.

## Concept

Instead of one `helm-values.yaml`, keep a values file per environment. Each file sets the namespace, hostname, resource limits, replicas, and environment variables appropriate for that stage.

```
my-app/
├── Dockerfile
├── helm-values.dev.yaml
├── helm-values.test.yaml
└── helm-values.prod.yaml
```

## Files

| File | Namespace | Hostname | Replicas | Notes |
|---|---|---|---|---|
| `dev.yaml` | `dev` | `dev.mysite.com` | 1 | Debug logging, minimal resources |
| `test.yaml` | `test` | `tst.mysite.com` | 1 | Mirrors prod config at lower scale |
| `prod.yaml` | `prod` | `mysite.com` | 2 | Stricter probes, higher resources |

## Deploying manually

```bash
# Dev
helm upgrade --install my-app /opt/helm-charts/app -f helm-values.dev.yaml -n dev --create-namespace

# Test
helm upgrade --install my-app /opt/helm-charts/app -f helm-values.test.yaml -n test --create-namespace

# Prod
helm upgrade --install my-app /opt/helm-charts/app -f helm-values.prod.yaml -n prod --create-namespace
```

## CI/CD

See `../github-actions/deploy-environments.yaml` for a GitHub Actions workflow that deploys to dev on every push, to test on tags, and to prod with manual approval.

## Git-push deploys per environment

Instead of deploying from CI, each environment can be its own git-push target: push the same repo to `deploy@server:staging.mysite.com` and `deploy@server:mysite.com`, and let a `.deploy/<app-name>.conf` per target pick the right values file (and optionally restrict which ref may be pushed). See `../monorepo/` for the conf format — it works for single-app repos with multiple environments too.

## Namespace setup

Create the namespaces and copy the registry pull secret to each:

```bash
for ns in dev test prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry kaniko-registry-creds \
    --docker-server=registry.mysite.com \
    --docker-username=username \
    --docker-password=<PASSWORD> \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
```
