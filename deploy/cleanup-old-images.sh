#!/bin/bash
# cleanup-old-images.sh — Prune an app's stale per-commit images after a deploy.
#
# Installed at /usr/local/bin/cleanup-old-images (root-owned) and invoked by the
# pre-receive hook via a narrow sudo grant:
#
#   sudo -n /usr/local/bin/cleanup-old-images <registry> <app> <current-tag> [keep]
#
# Every git push builds a new SHA-tagged image; without this, old tags pile up in
# both the node's containerd store and the private registry until the disk fills.
#
# This removes the app's stale images from:
#   1. the node's containerd store — keeps the running tag + :latest only
#      (rollback re-pulls from the registry, so the node needs no history)
#   2. the private registry — keeps the newest <keep> tags + :latest + current,
#      then runs garbage collection to reclaim the blobs
#
# Best-effort: it must never fail a deploy, so it always exits 0.

set -uo pipefail

REGISTRY="${1:?registry required}"
APP="${2:?app name required}"
CURRENT_TAG="${3:?current tag required}"
KEEP="${4:-5}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
CRICTL=(/usr/local/bin/k3s crictl)

echo "▶ Pruning old images for ${APP} (keep :latest, ${CURRENT_TAG}, +${KEEP} recent)"

# ── 1. Containerd: drop stale node images for this app ─────────────────────────
# The kaniko cache repo (${APP}/cache) lives under a different repository column,
# so the exact $1==repo match leaves it untouched.
node_removed=0
while read -r tag; do
  [ -z "$tag" ] && continue
  case "$tag" in
    "$CURRENT_TAG" | latest) continue ;;
  esac
  if "${CRICTL[@]}" rmi "${REGISTRY}/${APP}:${tag}" >/dev/null 2>&1; then
    echo "  ✓ removed node image ${APP}:${tag}"
    node_removed=$((node_removed + 1))
  fi
done < <("${CRICTL[@]}" images 2>/dev/null | awk -v repo="${REGISTRY}/${APP}" '$1 == repo {print $2}')
[ "$node_removed" -eq 0 ] && echo "  node images already clean"

# ── 2. Registry: prune old tags, then garbage-collect ──────────────────────────
REPOS_DIR=""
for _d in /var/lib/rancher/k3s/storage/pvc-*_registry_registry-pvc/docker/registry/v2/repositories; do
  [ -d "$_d" ] && { REPOS_DIR="$_d"; break; }   # skips the literal glob when no match
done
TAGS_DIR="${REPOS_DIR:-/nonexistent}/${APP}/_manifests/tags"

reg_deleted=0
if [ -d "$TAGS_DIR" ]; then
  kept_others=0
  # ls -t lists tags newest-first by mtime (each SHA tag is written once on push).
  # A glob can't sort by mtime, and tag names are git SHAs/"latest" (no spaces),
  # so iterating ls output is safe here.
  # shellcheck disable=SC2045
  for tag in $(ls -1t "$TAGS_DIR" 2>/dev/null); do
    case "$tag" in
      "$CURRENT_TAG" | latest) continue ;;   # always retained, never counted
    esac
    kept_others=$((kept_others + 1))
    [ "$kept_others" -le "$KEEP" ] && continue
    rm -rf "${TAGS_DIR:?}/${tag}"
    echo "  ✓ removed registry tag ${APP}:${tag}"
    reg_deleted=$((reg_deleted + 1))
  done
fi

if [ "$reg_deleted" -gt 0 ]; then
  echo "▶ Running registry garbage collection..."
  if kubectl exec -n registry deploy/registry -- \
    registry garbage-collect -m /etc/docker/registry/config.yml >/dev/null 2>&1; then
    echo "  ✓ registry garbage collection complete"
  else
    echo "  ⚠ registry garbage collection skipped/failed (non-fatal)"
  fi
else
  echo "  registry tags already within retention"
fi

exit 0
