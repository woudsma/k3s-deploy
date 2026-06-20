#!/usr/bin/env bash
# test/run.sh — Run setup.sh end-to-end against a throwaway "fresh VPS".
#
# Spins up a privileged systemd Ubuntu container (a faithful stand-in for a fresh
# Hetzner box), runs the real setup.sh inside it non-interactively, then asserts
# the cluster came up correctly.
#
# Reproducible & cheap to repeat: each run force-removes the previous test
# container and starts clean. The base image is built once and reused, so running
# this many times does NOT pile up images.
#
#   test/run.sh          build base (if needed) → run setup.sh headless → assert
#   test/run.sh interactive   same, but you answer setup.sh's prompts at a TTY
#   test/run.sh shell    open a shell in the last test container (for poking around)
#   test/run.sh clean    remove the test container and base image
#
# Notes on container vs. real VPS:
#   • K3s can't use the overlayfs snapshotter nested in Docker, so we inject
#     INSTALL_K3S_EXEC=--snapshotter=native. setup.sh is NOT modified — a real VPS
#     uses overlayfs fine; this is purely a test-environment accommodation.
#   • The optional prompts (hardening/swap/zsh/motd) are answered "no": they touch
#     host-level facilities (ufw, swapon, chsh) that aren't meaningful in a
#     container. The core install path — K3s, cert-manager, registry, secrets,
#     git-push deploys, monitoring — is what gets exercised.

set -uo pipefail

IMAGE="k8s-setup-test:base"
CONTAINER="k8s-setup-test"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Inputs fed to setup.sh's prompts, in order.
TEST_DOMAIN="test.local"
TEST_EMAIL="test@test.local"
TEST_REG_USER="testuser"
TEST_REG_PASS="testpass"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
blu() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }

# ── Subcommands ────────────────────────────────────────────────
INTERACTIVE=0
case "${1:-run}" in
  clean)
    if docker rm -f "$CONTAINER" >/dev/null 2>&1; then grn "Removed container $CONTAINER"; fi
    if docker rmi "$IMAGE" >/dev/null 2>&1; then grn "Removed image $IMAGE"; fi
    exit 0
    ;;
  shell)
    exec docker exec -it "$CONTAINER" bash
    ;;
  run) ;;
  interactive|-i|--interactive) INTERACTIVE=1 ;;
  *) red "Unknown command: $1 (use: run | interactive | shell | clean)"; exit 2 ;;
esac

# ── Preconditions ──────────────────────────────────────────────
command -v docker >/dev/null || { red "Docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { red "Docker daemon not running — start Docker Desktop"; exit 1; }

# ── 1. Base image (built once, reused) ─────────────────────────
blu "Building base image (cached after first run)…"
docker build -q -t "$IMAGE" -f "${REPO_ROOT}/test/Dockerfile" "${REPO_ROOT}/test" >/dev/null \
  || { red "Base image build failed"; exit 1; }

# ── 2. Fresh container (force-removes the previous one) ─────────
blu "Starting fresh test container…"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  "$IMAGE" >/dev/null || { red "Container failed to start"; exit 1; }

printf '  waiting for systemd'
for _ in $(seq 1 30); do
  s=$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)
  [[ "$s" == "running" || "$s" == "degraded" ]] && break
  printf '.'; sleep 2
done
echo " ${s:-?}"

# ── 3. Copy the repo in (so host files aren't mutated by sed) ──
blu "Copying repo into container…"
docker exec "$CONTAINER" mkdir -p /tmp/k3s-deploy
tar -C "$REPO_ROOT" --exclude='./.git' --exclude='./test' -cf - . \
  | docker exec -i "$CONTAINER" tar -C /tmp/k3s-deploy -xf -

# ── 3b. Pre-seed registry trust BEFORE k3s starts ─────────────
# The test registry is served by Traefik with a self-signed cert (cert-manager
# can't issue for test.local offline). Telling containerd to skip TLS verify and
# resolving the registry host to localhost must be in place before K3s installs —
# doing it afterward would require restarting k3s, which orphans port-holding pods
# (Traefik/registry) and breaks the cluster. A real VPS needs none of this.
docker exec "$CONTAINER" bash -c 'mkdir -p /etc/rancher/k3s && cat > /etc/rancher/k3s/registries.yaml <<EOF
configs:
  "registry.'"${TEST_DOMAIN}"'":
    tls:
      insecure_skip_verify: true
EOF
grep -q "registry.'"${TEST_DOMAIN}"'" /etc/hosts || echo "127.0.0.1 registry.'"${TEST_DOMAIN}"'" >> /etc/hosts'

# ── 4. Run setup.sh ───────────────────────────────────────────
blu "Running setup.sh (this pulls images — give it a few minutes)…"
if [ "$INTERACTIVE" -eq 1 ]; then
  # You answer the prompts yourself at a real TTY. The registry trust, CoreDNS
  # rewrite and assertions below are wired to ${TEST_DOMAIN}, so use that domain
  # for a clean pass; the other answers are free-form.
  cat <<NOTE
  Interactive mode — answer setup.sh's prompts yourself. For the checks to pass:
    • Domain:        ${TEST_DOMAIN}   ← must be this (registry trust + asserts use it)
    • Email:         anything (e.g. ${TEST_EMAIL})
    • Registry user: anything (e.g. ${TEST_REG_USER})
    • Registry pass: anything (e.g. ${TEST_REG_PASS})
    • Optional prompts (hardening / swap / zsh / motd): answer N
NOTE
  docker exec -it -e INSTALL_K3S_EXEC='--snapshotter=native' "$CONTAINER" \
    bash /tmp/k3s-deploy/setup.sh
  SETUP_RC=$?
else
  docker exec -i -e INSTALL_K3S_EXEC='--snapshotter=native' "$CONTAINER" \
    bash /tmp/k3s-deploy/setup.sh <<EOF
${TEST_DOMAIN}
${TEST_EMAIL}
${TEST_REG_USER}
${TEST_REG_PASS}
N
N
N
N
EOF
  SETUP_RC=$?
fi
if [ "$SETUP_RC" -eq 0 ]; then grn "setup.sh exited 0"; else red "setup.sh exited ${SETUP_RC}"; fi

# ── 5. Assertions ─────────────────────────────────────────────
blu "Verifying the cluster…"
# Give image-pulling workloads a moment to roll out before asserting.
docker exec "$CONTAINER" bash -c \
  'kubectl rollout status deploy/registry -n registry --timeout=120s;
   kubectl rollout status deploy/headlamp -n headlamp --timeout=120s' >/dev/null 2>&1 || true

PASS=0; FAIL=0
check() { # description, shell-snippet (run inside container)
  if docker exec "$CONTAINER" bash -c "$2" >/dev/null 2>&1; then
    grn "  ✓ $1"; PASS=$((PASS + 1))
  else
    red "  ✗ $1"; FAIL=$((FAIL + 1))
  fi
}

check "node is Ready"                 "kubectl get nodes --no-headers | grep -q ' Ready '"
check "system pods running (traefik)" "kubectl get pods -n kube-system | grep -q '^traefik.*Running'"
check "cert-manager available"        "kubectl wait --for=condition=available deploy --all -n cert-manager --timeout=10s"
check "registry pod is Running"       "kubectl get pods -n registry --no-headers | grep -q 'Running'"
check "kaniko-docker-config secret"   "kubectl get secret kaniko-docker-config"
check "kaniko-registry-creds secret"  "kubectl get secret kaniko-registry-creds"
check "registry-auth secret"          "kubectl get secret registry-auth -n registry"
check "headlamp deployed"             "kubectl get deploy headlamp -n headlamp"
check "trivy-scan cronjob"            "kubectl get cronjob trivy-scan"
check "deploy user exists"            "id deploy"
check "helm installed"                "command -v helm"
check "helm chart copied"             "test -f /opt/helm-charts/app/Chart.yaml"
check "cleanup-old-images installed"  "test -x /usr/local/bin/cleanup-old-images"
check "sudoers grant is valid"        "visudo -cf /etc/sudoers.d/deploy-cleanup"
check "domain placeholder replaced"   "grep -rq 'registry.test.local' /tmp/k3s-deploy/registry/registry.yaml"
# setup.sh keeps the placeholder in its own prompt text by design, so exclude it.
check "no mysite.com left in configs" "! grep -rq 'mysite.com' /tmp/k3s-deploy --include='*.yaml' --include='*.sh' --exclude='setup.sh'"

# ── 6. Deploy test: a real git-push of a static hello-world app ─
# Exercises the whole pipeline: git push → Kaniko build → push to the private
# registry → Helm deploy → reachable through Traefik. The build logs stream back
# over SSH exactly like the real Dokku-style experience.
blu "Deploying a sample app via git push (build logs stream below)…"

# In-cluster build/pull pods resolve registry.${TEST_DOMAIN} via CoreDNS → Traefik.
docker exec -i "$CONTAINER" kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  registry.override: |
    rewrite name registry.${TEST_DOMAIN} traefik.kube-system.svc.cluster.local
EOF
docker exec "$CONTAINER" kubectl rollout restart deploy/coredns -n kube-system >/dev/null 2>&1 || true
docker exec "$CONTAINER" kubectl rollout status deploy/coredns -n kube-system --timeout=90s >/dev/null 2>&1 || true

# Kaniko skips TLS verify for the self-signed test registry (no-op flag in prod).
docker exec "$CONTAINER" bash -c \
  'grep -q KANIKO_EXTRA_ARGS /home/deploy/.deploy.conf || echo '\''KANIKO_EXTRA_ARGS="--skip-tls-verify"'\'' >> /home/deploy/.deploy.conf'

docker exec "$CONTAINER" systemctl is-active ssh >/dev/null 2>&1 || docker exec "$CONTAINER" systemctl start ssh

# Stage the sample app and push it over SSH (the real user flow).
docker exec "$CONTAINER" rm -rf /root/hello-world
docker cp "${REPO_ROOT}/test/hello-world" "$CONTAINER:/root/hello-world"
docker exec "$CONTAINER" chown -R root:root /root/hello-world
docker exec "$CONTAINER" bash -c \
  'cd /root/hello-world && git init -q && git add -A && git -c user.email=t@t.local -c user.name=tester commit -qm "hello world"'
docker exec "$CONTAINER" bash -c \
  'cd /root/hello-world && GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" git push deploy@localhost:hello-world HEAD:main'
DEPLOY_RC=$?
if [ "$DEPLOY_RC" -eq 0 ]; then grn "git push deploy exited 0"; else red "git push deploy exited ${DEPLOY_RC}"; fi

blu "Verifying the deployed app…"
check "hello-world pod is Running"     "kubectl get pods -l app=hello-world --no-headers | grep -q ' Running'"
check "image pulled from registry"     "kubectl get pod -l app=hello-world -o jsonpath='{.items[0].spec.containers[0].image}' | grep -q '^registry.${TEST_DOMAIN}/hello-world:'"
check "page served through Traefik"    "curl -sk --resolve hello-world.${TEST_DOMAIN}:443:127.0.0.1 https://hello-world.${TEST_DOMAIN}/ | grep -q HELLO-FROM-K3S-DEPLOY-TEST"

# ── 7. Redeploy: a second push to exercise the upgrade path ────
# A new (empty) commit means a new SHA tag, so this goes through `helm upgrade`
# (revision 2) and the prune-old-images step with a real previous image present —
# not the first-install path.
blu "Redeploying with an empty commit (tests subsequent deploys)…"
docker exec "$CONTAINER" bash -c \
  'cd /root/hello-world && git -c user.email=t@t.local -c user.name=tester commit -q --allow-empty -m "redeploy" && GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" git push deploy@localhost:hello-world HEAD:main'
REDEPLOY_RC=$?
if [ "$REDEPLOY_RC" -eq 0 ]; then grn "second git push exited 0"; else red "second git push exited ${REDEPLOY_RC}"; fi

blu "Verifying the redeploy…"
# helm (unlike k3s's kubectl) doesn't default to the k3s kubeconfig — point it there.
check "helm reached revision 2"        "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm history hello-world -n default 2>/dev/null | grep -qE '^2[[:space:]]'"
check "rollout succeeded (1/1 ready)"  "kubectl rollout status deploy/hello-world -n default --timeout=60s"
# Retry briefly: during rollover there's a short gap before Traefik repoints to the new pod.
check "page still served after redeploy" "for _ in \$(seq 1 10); do curl -sk --resolve hello-world.${TEST_DOMAIN}:443:127.0.0.1 https://hello-world.${TEST_DOMAIN}/ | grep -q HELLO-FROM-K3S-DEPLOY-TEST && exit 0; sleep 2; done; exit 1"

# ── Summary ───────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ] && [ "$SETUP_RC" -eq 0 ] && [ "${DEPLOY_RC:-1}" -eq 0 ] && [ "${REDEPLOY_RC:-1}" -eq 0 ]; then
  grn "PASS — ${PASS}/$((PASS + FAIL)) checks (container left running; 'test/run.sh shell' to inspect)"
  exit 0
else
  red "FAIL — ${FAIL} check(s) failed, setup rc=${SETUP_RC}, deploy rc=${DEPLOY_RC:-?}, redeploy rc=${REDEPLOY_RC:-?} (container left running; 'test/run.sh shell' to inspect)"
  exit 1
fi
