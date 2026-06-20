# GitHub Actions

Two workflow options for deploying from GitHub Actions.

## deploy-ci.yaml — Build in CI

Builds the Docker image on the GitHub Actions runner, pushes it to the private registry, then deploys using `helm upgrade --install` with the project's `helm-values.yaml`.

The chart is checked out from this repo (`username/k3s-deploy`) during the workflow — update `CHART_REPO` in the workflow if your repo path differs.

**Repo secrets:**

| Secret | Value |
|---|---|
| `REGISTRY_USER` | Registry username (`username`) |
| `REGISTRY_PASS` | Registry password |
| `KUBECONFIG` | Contents of `/etc/rancher/k3s/k3s.yaml` (with public IP) |

## deploy-git-push.yaml — Build on server

Pushes the code to the server over SSH, where the `pre-receive` hook runs a Kaniko build and deploys using Helm — same as `git push deploy main` from your local machine.

**Repo secrets:**

| Secret | Value |
|---|---|
| `DEPLOY_SSH_KEY` | Private key authorized for the `deploy` user |
| `SERVER_IP` | Server IP address |

## deploy-environments.yaml — Multi-environment pipeline

Builds the image once, then deploys to dev, test, and prod with separate Helm values files per environment. Each environment is a separate namespace and GitHub Actions environment (for protection rules like manual approval on prod).

- `push to main/develop` → deploys to dev
- `push a tag (v*)` → deploys to test, then prod (after test succeeds)
- `workflow_dispatch` → manually deploy to any environment

Expects per-environment values files in the app repo (`helm-values.dev.yaml`, `helm-values.test.yaml`, `helm-values.prod.yaml`). See `../environments/` for examples.

**Repo secrets:** Same as CI build above (`REGISTRY_USER`, `REGISTRY_PASS`, `KUBECONFIG`).

## Which one to use?

- **CI build** — better for projects that need CI checks (tests, linting) before deploying, or when you want build logs in GitHub.
- **Git push** — simpler setup, build happens on the server, good for small projects where you don't need CI steps.
- **Environments** — staged rollouts across dev/test/prod with separate configs and optional manual approval gates.
