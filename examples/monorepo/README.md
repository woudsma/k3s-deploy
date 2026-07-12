# Monorepo / multiple deploy targets

Deploy several apps and environments from a single repository — each deploy
target is its own app name on the server, and the pushed repo carries one
`.deploy/<app-name>.conf` per target.

## Concept

The pre-receive hook looks for `.deploy/<app-name>.conf` in the pushed tree,
where `<app-name>` is the repo name you pushed to (`deploy@server:app-name`).
If present, it selects the build context, Dockerfile, Helm values file, build
args and an allowed ref for that target. Without a conf, the hook behaves
exactly as before (root `Dockerfile` + root `helm-values.yaml`).

```
my-project/                        # one repo, four deploy targets
├── apps/
│   ├── web/
│   │   └── Dockerfile
│   └── api/
│       └── Dockerfile
└── .deploy/
    ├── mysite.com.conf            # prod web    (push master)
    ├── staging.mysite.com.conf    # staging web (push dev)
    ├── api.mysite.com.conf        # prod api    (push master)
    ├── api.staging.mysite.com.conf
    └── helm/
        ├── web.prod.yaml
        ├── web.staging.yaml
        ├── api.prod.yaml
        └── api.staging.yaml
```

One remote per target on the dev machine:

```bash
git remote add web-prod    deploy@<server-ip>:mysite.com
git remote add web-staging deploy@<server-ip>:staging.mysite.com
git remote add api-prod    deploy@<server-ip>:api.mysite.com
git remote add api-staging deploy@<server-ip>:api.staging.mysite.com

git push web-staging dev      # deploy web to staging
git push api-prod master      # deploy api to prod
```

## Conf format

Plain `KEY="value"` lines. Keys are parsed with a whitelist (the file is never
sourced), unknown keys are ignored. All keys are optional.

```bash
# .deploy/staging.mysite.com.conf

# Docker build context, relative to the repo root (default: .)
BUILD_CONTEXT="apps/web"

# Dockerfile path, relative to BUILD_CONTEXT (default: Dockerfile)
DOCKERFILE="Dockerfile"

# Helm values file, relative to the repo root (default: helm-values.yaml)
HELM_VALUES=".deploy/helm/web.staging.yaml"

# Space-separated KEY=VALUE pairs passed as --build-arg to Kaniko.
# Values must not contain spaces. Only put public values here.
BUILD_ARGS="API_URL=https://api.staging.mysite.com PUBLIC_KEY=abc123"

# Only accept pushes of this ref — guards against pushing dev to prod.
ALLOWED_REF="refs/heads/dev"
```

## Notes

- The image is tagged after the repo name you push to
  (`registry.mysite.com/staging.mysite.com:<sha>`), so set
  `image.repository: staging.mysite.com` in that target's values file — the
  chart's default (`.name`) won't match when the app name contains dots.
- Paths may not be absolute or contain `..`.
- Runtime secrets don't belong in the conf or values file — create a
  Kubernetes secret once and reference it via `env` + `secretKeyRef` (see
  `charts/app/values.yaml`).
