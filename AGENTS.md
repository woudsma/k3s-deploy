# Deploying apps to this cluster — agent guide

You are reading this because a user wants to deploy an app to their self-hosted
K3s cluster.

**The cluster:** single-node K3s on a VPS with Traefik ingress, automatic
Let's Encrypt TLS per subdomain (wildcard DNS `*.<domain>` already points at
the server), a private in-cluster container registry, and Dokku-style
git-push deploys — a push builds the image on the server with Kaniko and
deploys it with Helm. Build logs stream back over SSH during the push.

## What to ask the user (if not already known)

1. **Cluster domain** — e.g. `example.com`. Everywhere below, replace `<domain>`.
2. **Server address** — the IP or hostname used for the git remote (often the domain itself).
3. **App name** — the subdomain to deploy under, e.g. `my-app` → `my-app.<domain>`.

Nothing else is required. No registry login, no kubeconfig, no manifests —
just SSH access as the `deploy` user (the user's SSH key is already installed
on the server).

## The recipe

Every app needs exactly two things in its repo root:

```
my-app/
├── Dockerfile          # how to build it (any language)
└── helm-values.yaml    # the only Kubernetes-related file
```

Then deploy with git:

```bash
git remote add deploy deploy@<server>:my-app   # one-time
git push deploy main
```

That's it. The first push auto-creates the repo on the server, builds the
image, pushes it to the private registry, and deploys via
`helm upgrade --install`. Subsequent pushes are updates. The app is live at
`https://my-app.<domain>` with a valid certificate within ~a minute of the
cert being issued. Don't commit yourself, always ask the user to commit and 
push.

### ⚠️ Rules that will bite you if ignored

- **`name` in `helm-values.yaml` must equal the app name in the git remote**
  (`deploy@<server>:my-app` → `name: my-app`). The image is tagged
  `registry.<domain>/<app-name>:<commit-sha>` after the *remote* name, and the
  chart resolves the image from `name` — a mismatch means `ImagePullBackOff`.
  (If they must differ, set `image.repository:` to the remote app name.)
- **The default health probe is HTTP GET `/` on the container port.** If the
  app doesn't return 2xx/3xx on `/`, set `probes.path` (or `probes.type: exec`)
  or the rollout will fail.
- **Never put secrets in `helm-values.yaml` or build args** — they'd be in git.
  See [Secrets](#secrets) below.
- The app must listen on `port` (default 80). Set `port:` to whatever the
  container actually listens on; the Service still exposes 80/443 externally.
- Pushes deploy the *committed* tree. Uncommitted changes are not deployed.

## helm-values.yaml reference

All keys are optional except `name`. These are the chart defaults — only
override what differs:

```yaml
name: ""                  # REQUIRED — must match the git remote app name

image:
  registry: registry.<domain>
  repository: ""          # defaults to .name
  tag: latest             # overridden per-deploy with the commit SHA
  pullSecrets: true       # set false for public images (postgres, redis, …)

replicas: 1
port: 80                  # the port the container listens on

service:
  port: 80
  targetPort: ""          # defaults to .port

ingress:
  enabled: true           # false for internal services (databases)
  hosts:
    - ""                  # e.g. my-app.<domain>; multiple hosts allowed
  annotations: {}

probes:
  type: http              # http | exec
  path: /
  execCommand: []         # e.g. ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 0
  periodSeconds: 10
  timeoutSeconds: 1
  failureThreshold: 3
  startup: true           # fast-poll startup probe; app gets 2s×30 = 60s to boot
  startupPeriodSeconds: 2
  startupFailureThreshold: 30

terminationGracePeriodSeconds: 30   # lower (e.g. 10) if the app exits fast on SIGTERM

resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits:   { cpu: 200m, memory: 128Mi }

strategy: RollingUpdate   # use Recreate for single-writer persistent volumes

command: []               # override container entrypoint
args: []

env: []                   # standard k8s env list; supports valueFrom/secretKeyRef

podAnnotations: {}

persistence:              # stateful apps
  enabled: false
  size: 1Gi
  mountPath: /data

nodeSelector: {}
tolerations: []
```

## Recipes by app type

### Static website (~4 lines)

```yaml
name: my-website
ingress:
  hosts:
    - my-website.<domain>
```

### API (Node.js / Python / Go / …)

```yaml
name: my-api
port: 3000
ingress:
  hosts:
    - my-api.<domain>
probes:
  path: /health
  initialDelaySeconds: 10
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }
env:
  - name: NODE_ENV
    value: production
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: my-api-secrets
        key: database-url
```

### Multi-domain site

```yaml
name: my-site
ingress:
  hosts:
    - my-site.<domain>
    - www.my-site.<domain>
```

### Stateful web app (embedded SQLite, uploads, …)

```yaml
name: my-app
port: 8080
ingress:
  hosts:
    - my-app.<domain>
persistence:
  enabled: true
  size: 5Gi
  mountPath: /data
strategy: Recreate        # single writer on a ReadWriteOnce volume
probes:
  path: /healthz
env:
  - name: DATA_DIR
    value: /data
```

### PostgreSQL (public image — no Dockerfile, no git push)

Databases use public images and are deployed directly with Helm on the server
(the chart lives at `/opt/helm-charts/app`), not via git push:

```yaml
# postgres-values.yaml
name: my-db
image:
  registry: ""
  repository: postgres
  tag: "16"
  pullSecrets: false
port: 5432
service:
  port: 5432
strategy: Recreate
ingress:
  enabled: false          # internal only — apps reach it at my-db:5432
probes:
  type: exec
  execCommand: ["pg_isready", "-U", "postgres"]
  initialDelaySeconds: 30
resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }
persistence:
  enabled: true
  size: 5Gi
  mountPath: /var/lib/postgresql/data
env:
  - name: POSTGRES_PASSWORD
    valueFrom:
      secretKeyRef:
        name: my-db-secrets
        key: postgres-password
```

```bash
# On the server (as root):
kubectl create secret generic my-db-secrets \
  --from-literal=postgres-password=$(openssl rand -hex 24)
helm upgrade --install my-db /opt/helm-charts/app -f postgres-values.yaml
```

Other apps connect with `DATABASE_URL=postgres://postgres:<pw>@my-db:5432/postgres`
(in-cluster DNS: the Service name is the `name` value). Redis is identical with
`repository: redis`, `tag: "7"`, port 6379, probe `["redis-cli", "ping"]`.

## Secrets

Runtime secrets live in Kubernetes secrets, created **once, before the first
deploy**, on the server (as root) or via any kubectl with cluster access:

```bash
kubectl create secret generic my-app-secrets \
  --from-literal=API_TOKEN=$(openssl rand -hex 24) \
  --from-literal=database-url='postgres://…'
```

Reference them from `helm-values.yaml` with `env` + `secretKeyRef` (see the API
recipe). If the user can't run kubectl, give them the exact command to run over
SSH as root on the server.

## Monorepos / multiple deploy targets (staging + prod, web + api)

One repo can push to several app names. Add a `.deploy/<app-name>.conf`
(plain `KEY="value"` lines — parsed, never sourced) per target:

```bash
# .deploy/staging.<domain>.conf
BUILD_CONTEXT="apps/web"                     # docker context, relative to repo root (default .)
DOCKERFILE="Dockerfile"                      # relative to BUILD_CONTEXT (default Dockerfile)
HELM_VALUES=".deploy/helm/web.staging.yaml"  # relative to repo root (default helm-values.yaml)
BUILD_ARGS="API_URL=https://api.staging.<domain>"  # space-separated, public values only
ALLOWED_REF="refs/heads/dev"                 # reject pushes of any other ref
```

```bash
git remote add web-staging deploy@<server>:staging.<domain>
git remote add web-prod    deploy@<server>:<domain>
git push web-staging dev
git push web-prod   master
```

Gotcha for **dotted app names** (like `staging.<domain>`): the image is tagged
after the remote name, so that target's values file must set
`image.repository: staging.<domain>` explicitly — the default (`.name`) won't
match. Paths in the conf may not be absolute or contain `..`. No conf file →
plain single-app behavior.

## Verifying and troubleshooting

The push itself streams the build and rollout status — if it ends with
`✓ <app> deployed`, it worked. For more, use kubectl (needs kubeconfig from
`/etc/rancher/k3s/k3s.yaml` on the server, with `127.0.0.1` replaced by the
server IP) or run these over SSH as root:

```bash
kubectl get pods                                  # app pods (default namespace)
kubectl logs deploy/<name> --tail=100             # app logs
kubectl describe pod -l app=<name>                # why a pod isn't starting
kubectl get certificates                          # TLS cert status (READY=True)
helm status <name>                                # what's deployed
helm rollback <name>                              # revert a bad deploy
```

Common failures:

| Symptom | Cause |
|---|---|
| `ImagePullBackOff` | `name` ≠ git remote app name (or missing `image.repository` for dotted names) |
| Rollout timeout, pod restarting | Probe failing — wrong `probes.path` or wrong `port` |
| Push rejected with ref message | Target's `ALLOWED_REF` doesn't match the pushed branch |
| Cert not ready after a few minutes | DNS for that subdomain doesn't resolve to the server |
| Build fails immediately | Dockerfile error, or `BUILD_CONTEXT`/`DOCKERFILE` path wrong |

## GitHub Actions instead of git push (optional)

CI can build the image, push it to `registry.<domain>` (basic auth:
`REGISTRY_USER`/`REGISTRY_PASS` secrets), and run
`helm upgrade --install <name> /opt/helm-charts/app -f helm-values.yaml --set image.tag=<sha>`
using a `KUBECONFIG` secret. Prefer plain git push unless the user already has
CI requirements — it's simpler and needs no repo secrets. Full workflow
examples: [examples/github-actions/](https://github.com/woudsma/k3s-deploy/tree/main/examples/github-actions).
