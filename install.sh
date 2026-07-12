#!/bin/sh
# install.sh — one-line bootstrap for a fresh Ubuntu server.
#
#   curl -fsSL https://raw.githubusercontent.com/woudsma/k3s-deploy/main/install.sh | sh
#
# Installs git/curl, clones this repo, and launches the interactive setup.sh.
# Everything configurable via env vars (all optional):
#   K3S_DEPLOY_REPO  git URL to clone            (default: this repo)
#   K3S_DEPLOY_REF   branch/tag/commit to check out (default: main)
#   K3S_DEPLOY_DIR   where to clone it            (default: /opt/k3s-deploy)

set -eu

REPO_URL="${K3S_DEPLOY_REPO:-https://github.com/woudsma/k3s-deploy.git}"
REPO_REF="${K3S_DEPLOY_REF:-main}"
TARGET_DIR="${K3S_DEPLOY_DIR:-/opt/k3s-deploy}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run as root — this installs system packages, K3s, and cluster services." >&2
  exit 1
fi

echo "▶ Installing prerequisites (git, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl

if [ -d "${TARGET_DIR}/.git" ]; then
  echo "▶ Updating existing checkout in ${TARGET_DIR}..."
  git -C "${TARGET_DIR}" fetch --depth 1 origin "${REPO_REF}"
  git -C "${TARGET_DIR}" checkout -f "${REPO_REF}"
  git -C "${TARGET_DIR}" reset --hard "origin/${REPO_REF}"
else
  echo "▶ Cloning ${REPO_URL} (${REPO_REF}) into ${TARGET_DIR}..."
  git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${TARGET_DIR}"
fi

echo "▶ Launching setup.sh..."
# When run via `curl | sh`, stdin is the piped script — re-attach the terminal so
# setup.sh's interactive prompts can read the user's answers.
exec bash "${TARGET_DIR}/setup.sh" < /dev/tty
