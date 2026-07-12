#!/bin/bash
# setup.sh — Interactive server setup for the K8s cluster.
#
# Easiest path is the one-liner, which fetches the repo and runs this script:
#   curl -fsSL https://raw.githubusercontent.com/woudsma/k3s-deploy/main/install.sh | sh
#
# Or run this directly on a fresh Ubuntu VPS after rsync'ing this repo:
#   rsync -a --exclude='.git' . root@<server-ip>:/tmp/k3s-deploy
#   ssh root@<server-ip>
#   bash /tmp/k3s-deploy/setup.sh
#
# Or just run the manual steps in the README — this script does the same thing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_IP="$(hostname -I | awk '{print $1}')"

# ── Prompts ────────────────────────────────────────────────────

read -rp "Domain (e.g. mysite.com): " DOMAIN
read -rp "Email for Let's Encrypt certificates: " ACME_EMAIL
read -rp "Registry username: " REG_USER
read -rsp "Registry password: " REG_PASS
echo

if [ -z "$DOMAIN" ] || [ -z "$ACME_EMAIL" ] || [ -z "$REG_USER" ] || [ -z "$REG_PASS" ]; then
  echo "Error: all fields are required."
  exit 1
fi

REGISTRY="registry.${DOMAIN}"

read -rp "Set up security hardening (firewall, fail2ban, disable password auth)? [y/N] " DO_SECURITY
read -rp "Add 1GB swap space? [y/N] " DO_SWAP
read -rp "Install zsh + oh-my-zsh? [y/N] " DO_ZSH
read -rp "Install login banner (motd.sh — shows cluster status on SSH login)? [y/N] " DO_MOTD

# ── Replace domain in config files ─────────────────────────────

echo ""
echo "▶ Updating domain to ${DOMAIN}..."

find "${SCRIPT_DIR}" -type f \( -name '*.yaml' -o -name '*.sh' \) \
  ! -name 'setup.sh' \
  -exec sed -i "s/mysite\.com/${DOMAIN}/g" {} +

sed -i "s/info@${DOMAIN}/${ACME_EMAIL}/" \
  "${SCRIPT_DIR}/cert-manager/cluster-issuer.yaml"

# ── apt update ─────────────────────────────────────────────────

echo ""
echo "▶ Updating packages..."
apt update -y

# ── Install K3s ────────────────────────────────────────────────

echo ""
echo "▶ Installing K3s..."

# The K3s installer normally resolves the "stable" channel via update.k3s.io, but
# that host is load-balanced across backends and some intermittently serve a bogus
# "TRAEFIK DEFAULT CERT" (curl: (60) subjectAltName / SSL verify errors). Pin the
# version from GitHub instead so the installer skips the channel lookup entirely
# and pulls the binary straight from github.com. Falls back to the channel if the
# GitHub lookup is unavailable (e.g. API rate limit).
K3S_RELEASE_JSON="$(curl -fsSL --max-time 20 \
  https://api.github.com/repos/k3s-io/k3s/releases/latest 2>/dev/null || true)"
K3S_VERSION="$(awk -F'"' '/"tag_name"/{print $4; exit}' <<<"${K3S_RELEASE_JSON}")"

if [ -n "${K3S_VERSION}" ]; then
  echo "  Installing K3s ${K3S_VERSION} (pinned from GitHub, skipping update.k3s.io)..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -
else
  echo "  Could not resolve version from GitHub; falling back to the stable channel..."
  curl -sfL https://get.k3s.io | sh -
fi

echo "  Waiting for node to be ready..."
until kubectl get nodes &>/dev/null; do sleep 2; done
kubectl wait --for=condition=Ready node --all --timeout=120s

# Set up 'k' alias for kubectl
if [ ! -f /etc/profile.d/kubectl-alias.sh ]; then
  echo "alias k='kubectl'" > /etc/profile.d/kubectl-alias.sh
  chmod 644 /etc/profile.d/kubectl-alias.sh
fi

# ── Security hardening (optional) ──────────────────────────────

if [[ "${DO_SECURITY,,}" == "y" ]]; then
  echo ""
  echo "▶ Security hardening..."

  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart ssh

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 6443/tcp
  ufw --force enable

  apt install fail2ban -y
  systemctl enable fail2ban
fi

# ── Swap space (optional) ──────────────────────────────────────

if [[ "${DO_SWAP,,}" == "y" ]]; then
  if [ -f /swapfile ]; then
    echo ""
    echo "▶ Swap already exists, skipping..."
  else
    echo ""
    echo "▶ Setting up 1GB swap space..."
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

# ── cert-manager ───────────────────────────────────────────────

echo ""
echo "▶ Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=available deployment --all -n cert-manager --timeout=120s

# "available" doesn't mean the admission webhook is serving yet, so applying the
# ClusterIssuer can fail with an x509 webhook error — retry until it's accepted.
echo "  Waiting for cert-manager webhook, then creating ClusterIssuer..."
for _ in $(seq 1 30); do
  if kubectl apply -f "${SCRIPT_DIR}/cert-manager/cluster-issuer.yaml" >/dev/null 2>&1; then
    echo "  ClusterIssuer created"
    break
  fi
  sleep 5
done
# Final attempt surfaces the real error (and aborts) if it never became ready.
kubectl apply -f "${SCRIPT_DIR}/cert-manager/cluster-issuer.yaml"

# ── Private registry ──────────────────────────────────────────

echo ""
echo "▶ Deploying private registry..."
kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f -

apt install apache2-utils -y
htpasswd -Bbc /tmp/registry-htpasswd "$REG_USER" "$REG_PASS"
kubectl create secret generic registry-auth \
  --from-file=htpasswd=/tmp/registry-htpasswd \
  -n registry --dry-run=client -o yaml | kubectl apply -f -
rm /tmp/registry-htpasswd

kubectl apply -f "${SCRIPT_DIR}/registry/registry.yaml"

# ── Kaniko / pull secrets ──────────────────────────────────────

echo ""
echo "▶ Creating registry secrets..."

cat > /tmp/docker-config.json <<EOF
{"auths":{"${REGISTRY}":{"username":"${REG_USER}","password":"${REG_PASS}"}}}
EOF
kubectl create secret generic kaniko-docker-config \
  --from-file=config.json=/tmp/docker-config.json \
  --dry-run=client -o yaml | kubectl apply -f -
rm /tmp/docker-config.json

kubectl create secret docker-registry kaniko-registry-creds \
  --docker-server="$REGISTRY" \
  --docker-username="$REG_USER" \
  --docker-password="$REG_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Git-push deploy system ────────────────────────────────────

echo ""
echo "▶ Setting up git-push deploys..."
bash "${SCRIPT_DIR}/deploy/setup-deploy.sh" "$(cat ~/.ssh/authorized_keys)"

# ── Monitoring ─────────────────────────────────────────────────

echo ""
echo "▶ Deploying Headlamp dashboard..."
kubectl apply -f "${SCRIPT_DIR}/monitoring/headlamp.yaml"

HEADLAMP_TOKEN=$(kubectl create token headlamp -n headlamp --duration=8760h 2>/dev/null || echo "(token generation failed — create manually after setup)")

echo ""
echo "▶ Setting up image vulnerability scanning (Trivy Operator)..."
# Continuous, language-agnostic scanning. The operator watches workloads and emits
# VulnerabilityReport CRDs (kubectl get vulnerabilityreports -n default). It reuses
# each workload's imagePullSecrets, so it scans private-registry images too.
kubectl apply -f "https://raw.githubusercontent.com/aquasecurity/trivy-operator/v0.31.2/deploy/static/trivy-operator.yaml"
# Scope to the default namespace, report only HIGH/CRITICAL, hide CVEs with no fix
# available, and pin the scanner to the latest Trivy.
kubectl -n trivy-system patch configmap trivy-operator-trivy-config --type merge \
  -p '{"data":{"trivy.severity":"HIGH,CRITICAL","trivy.ignoreUnfixed":"true","trivy.tag":"0.71.2"}}'
kubectl -n trivy-system set env deployment/trivy-operator OPERATOR_TARGET_NAMESPACES=default

# ── zsh + oh-my-zsh (optional) ─────────────────────────────────

if [[ "${DO_ZSH,,}" == "y" ]]; then
  echo ""
  echo "▶ Installing zsh + oh-my-zsh..."
  apt install zsh -y
  # oh-my-zsh's installer exits non-zero if ~/.oh-my-zsh already exists, which
  # would abort this script on a re-run — only install it the first time.
  if [ ! -d "${HOME}/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  fi

  # zsh-autosuggestions: clone into oh-my-zsh's custom plugins and enable it so
  # it's active on every login (oh-my-zsh only downloads plugins you list).
  ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"
  if [ ! -d "${ZSH_CUSTOM_DIR}/plugins/zsh-autosuggestions" ]; then
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions \
      "${ZSH_CUSTOM_DIR}/plugins/zsh-autosuggestions"
  fi
  # append it to the plugins=(...) array (the default .zshrc ships with `plugins=(git)`)
  if ! grep -q 'zsh-autosuggestions' ~/.zshrc; then
    sed -i 's/^plugins=(\(.*\))/plugins=(\1 zsh-autosuggestions)/' ~/.zshrc
  fi
  if ! grep -q "':omz:update' mode disabled" ~/.zshrc 2>/dev/null; then
    echo "zstyle ':omz:update' mode disabled" >> ~/.zshrc
  fi

  # zsh doesn't source /etc/profile.d/ — add the kubectl alias to .zshrc
  if ! grep -q "alias k='kubectl'" ~/.zshrc; then
    echo -e "\nalias k='kubectl'" >> ~/.zshrc
  fi

  chsh -s "$(which zsh)"
fi

# ── motd (optional) ───────────────────────────────────────────

if [[ "${DO_MOTD,,}" == "y" ]]; then
  echo ""
  echo "▶ Installing login banner..."
  cp "${SCRIPT_DIR}/deploy/motd.sh" /etc/profile.d/k8s-motd.sh
  chmod 644 /etc/profile.d/k8s-motd.sh

  # zsh doesn't source /etc/profile.d/ — add an async loader to .zshrc so the
  # prompt is usable immediately while the (slow) cluster status renders above it.
  if [ -f ~/.zshrc ] && ! grep -q 'k8s-motd.sh' ~/.zshrc; then
    cat >> ~/.zshrc <<'ZSHRC'

# K8s cluster status — rendered asynchronously so the shell is usable immediately.
# Helpers (help, motd) load synchronously; the live status streams in above the
# prompt as it becomes ready, so you can start typing right away.
K8S_MOTD_NO_STATUS=1 source /etc/profile.d/k8s-motd.sh
if [[ -o interactive ]] && [[ -z ${_K8S_MOTD_SHOWN:-} ]]; then
  _K8S_MOTD_SHOWN=1
  zmodload zsh/system 2>/dev/null
  _k8s_motd_render() {
    local chunk
    if sysread -i $1 chunk 2>/dev/null; then
      print -rn -- "$chunk"
      zle -I
    else
      zle -F $1
      exec {_k8s_motd_fd}<&-
      zle -I
    fi
  }
  exec {_k8s_motd_fd}< <(K8S_MOTD_STATUS_ONLY=1 /etc/profile.d/k8s-motd.sh 2>/dev/null)
  zle -F $_k8s_motd_fd _k8s_motd_render
fi
ZSHRC
  fi
fi

# ── Done ───────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  ✅ Cluster setup complete!"
echo "============================================"
echo ""
echo "Remaining steps (do these manually):"
echo ""
echo "1. Point DNS to this server:"
echo "   Add an A record for *.${DOMAIN} → ${SERVER_IP}"
echo ""
echo "2. Copy kubeconfig to your local machine:"
echo "   scp root@${SERVER_IP}:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
echo "   Then replace 127.0.0.1 with ${SERVER_IP} in that file."
echo ""
echo "3. Test a deploy:"
echo "   git remote add deploy deploy@${SERVER_IP}:test-app"
echo "   git push deploy main"
echo ""
echo "4. Log in to Headlamp dashboard:"
echo "   https://headlamp.${DOMAIN}"
echo "   Token: ${HEADLAMP_TOKEN}"
echo ""
echo "5. For GitHub Actions, add these repo secrets:"
echo "   KUBECONFIG    — contents of ~/.kube/config (with server IP)"
echo "   REGISTRY_USER — ${REG_USER}"
echo "   REGISTRY_PASS — (the password you just entered)"
echo ""
