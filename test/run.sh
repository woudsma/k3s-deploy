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
#   test/run.sh          build base (if needed) → run setup.sh → assert
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
case "${1:-run}" in
  clean)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 && grn "Removed container $CONTAINER" || true
    docker rmi "$IMAGE" >/dev/null 2>&1 && grn "Removed image $IMAGE" || true
    exit 0
    ;;
  shell)
    exec docker exec -it "$CONTAINER" bash
    ;;
  run) ;;
  *) red "Unknown command: $1 (use: run | shell | clean)"; exit 2 ;;
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

# ── 4. Run setup.sh non-interactively ─────────────────────────
blu "Running setup.sh (this pulls images — give it a few minutes)…"
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
[ "$SETUP_RC" -eq 0 ] && grn "setup.sh exited 0" || red "setup.sh exited ${SETUP_RC}"

# ── 5. Assertions ─────────────────────────────────────────────
blu "Verifying the cluster…"
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
check "no mysite.com left in configs" "! grep -rq 'mysite.com' /tmp/k3s-deploy --include='*.yaml' --include='*.sh'"

# ── Summary ───────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ] && [ "$SETUP_RC" -eq 0 ]; then
  grn "PASS — ${PASS}/$((PASS + FAIL)) checks (container left running; 'test/run.sh shell' to inspect)"
  exit 0
else
  red "FAIL — ${FAIL} check(s) failed, setup rc=${SETUP_RC} (container left running; 'test/run.sh shell' to inspect)"
  exit 1
fi
