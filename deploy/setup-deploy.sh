#!/bin/bash
# setup-deploy.sh — Run on the K3s server to enable git-push deploys.
#
# Usage:
#   scp -r deploy/ root@server:/tmp/deploy-setup
#   ssh root@server 'bash /tmp/deploy-setup/setup-deploy.sh "ssh-ed25519 AAAA..."'
#
# Or from this repo:
#   cat ~/.ssh/id_ed25519.pub | ssh root@server 'bash -s' < deploy/setup-deploy.sh

set -euo pipefail

DEPLOY_USER="deploy"
DEPLOY_HOME="/home/${DEPLOY_USER}"
BUILD_DIR="/opt/build-contexts"
CHART_DIR="/opt/helm-charts/app"
REGISTRY="registry.mysite.com"
NAMESPACE="default"

# ── Read SSH public key ────────────────────────────────────────
SSH_KEY="${1:-}"
if [ -z "$SSH_KEY" ]; then
  echo "Reading SSH public key from stdin..."
  read -r SSH_KEY
fi

if [ -z "$SSH_KEY" ]; then
  echo "Error: SSH public key required."
  echo "Usage: $0 'ssh-ed25519 AAAA...'"
  exit 1
fi

echo "▶ Setting up git-push deploy system..."

# ── Create deploy user ─────────────────────────────────────────
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
  echo "  Created user: ${DEPLOY_USER}"
else
  echo "  User ${DEPLOY_USER} already exists"
fi

# ── Install deploy-shell ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/deploy-shell" ]; then
  cp "${SCRIPT_DIR}/deploy-shell" /usr/local/bin/deploy-shell
else
  echo "Error: deploy-shell not found in ${SCRIPT_DIR}"
  exit 1
fi
chmod 755 /usr/local/bin/deploy-shell
chsh -s /usr/local/bin/deploy-shell "$DEPLOY_USER"
echo "  Installed deploy-shell"

# ── Install shared pre-receive hook ────────────────────────────
if [ -f "${SCRIPT_DIR}/pre-receive-hook" ]; then
  cp "${SCRIPT_DIR}/pre-receive-hook" "${DEPLOY_HOME}/pre-receive-hook"
else
  echo "Error: pre-receive-hook not found in ${SCRIPT_DIR}"
  exit 1
fi
chmod 755 "${DEPLOY_HOME}/pre-receive-hook"
chown "$DEPLOY_USER":"$DEPLOY_USER" "${DEPLOY_HOME}/pre-receive-hook"
echo "  Installed pre-receive hook"

# ── Install image cleanup script + narrow sudo grant ───────────
if [ -f "${SCRIPT_DIR}/cleanup-old-images.sh" ]; then
  cp "${SCRIPT_DIR}/cleanup-old-images.sh" /usr/local/bin/cleanup-old-images
  chown root:root /usr/local/bin/cleanup-old-images
  chmod 755 /usr/local/bin/cleanup-old-images
  # Let the unprivileged deploy user run ONLY this one script as root.
  echo "${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/local/bin/cleanup-old-images" \
    > /etc/sudoers.d/deploy-cleanup
  chmod 440 /etc/sudoers.d/deploy-cleanup
  if visudo -cf /etc/sudoers.d/deploy-cleanup >/dev/null; then
    echo "  Installed cleanup-old-images + sudo grant"
  else
    echo "  Error: invalid sudoers file — removing" >&2
    rm -f /etc/sudoers.d/deploy-cleanup
    exit 1
  fi
else
  echo "  Warning: cleanup-old-images.sh not found — old images won't be pruned"
fi

# ── Write deploy config ───────────────────────────────────────
cat > "${DEPLOY_HOME}/.deploy.conf" <<EOF
REGISTRY="${REGISTRY}"
NAMESPACE="${NAMESPACE}"
CHART_PATH="${CHART_DIR}"
EOF
chown "$DEPLOY_USER":"$DEPLOY_USER" "${DEPLOY_HOME}/.deploy.conf"
echo "  Wrote config (registry=${REGISTRY}, namespace=${NAMESPACE}, chart=${CHART_DIR})"

# ── Set up SSH authorized_keys ─────────────────────────────────
mkdir -p "${DEPLOY_HOME}/.ssh"
echo "$SSH_KEY" > "${DEPLOY_HOME}/.ssh/authorized_keys"
chmod 700 "${DEPLOY_HOME}/.ssh"
chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "${DEPLOY_HOME}/.ssh"
echo "  Configured SSH key"

# ── Create build contexts directory ────────────────────────────
mkdir -p "$BUILD_DIR"
chown "$DEPLOY_USER":"$DEPLOY_USER" "$BUILD_DIR"
echo "  Created ${BUILD_DIR}"

# ── Copy kubeconfig for the deploy user ────────────────────────
mkdir -p "${DEPLOY_HOME}/.kube"
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
  cp /etc/rancher/k3s/k3s.yaml "${DEPLOY_HOME}/.kube/config"
  # Keep 127.0.0.1 since we're on the same server
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "${DEPLOY_HOME}/.kube"
  chmod 600 "${DEPLOY_HOME}/.kube/config"
  echo "  Copied kubeconfig"
else
  echo "  Warning: /etc/rancher/k3s/k3s.yaml not found — copy kubeconfig manually"
fi

# ── Install Helm ───────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  echo "▶ Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "  Installed Helm $(helm version --short)"
else
  echo "  Helm already installed ($(helm version --short))"
fi

# ── Copy Helm chart to server ──────────────────────────────────
if [ -d "${SCRIPT_DIR}/../charts/app" ]; then
  mkdir -p "$CHART_DIR"
  cp -r "${SCRIPT_DIR}/../charts/app/"* "$CHART_DIR/"
  echo "  Copied app chart to ${CHART_DIR}"
else
  echo "  Warning: charts/app not found in repo — copy it manually to ${CHART_DIR}"
fi

# ── Done ───────────────────────────────────────────────────────
echo ""
echo "✅ Git-push deploy is ready!"
echo ""
echo "From your local machine:"
echo "  git remote add deploy deploy@$(hostname -I | awk '{print $1}'):my-app"
echo "  git push deploy main"
echo ""
echo "Repos are auto-created on first push."
