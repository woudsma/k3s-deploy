#!/bin/bash
# motd.sh — Kubernetes cluster status shown on login.
#
# Install:
#   sudo cp deploy/motd.sh /etc/profile.d/k8s-motd.sh
#   sudo chmod 644 /etc/profile.d/k8s-motd.sh
#
# Requires: kubectl accessible on the PATH.

# Skip for non-interactive shells (scp, git push, etc.)
[[ $- != *i* ]] && return

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# bar PERCENT COLOR — render a fixed-width [####----] meter colored by COLOR.
bar() {
  local pct="$1" color="$2" width=20 filled empty
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled="$width"
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( width - filled ))
  printf '%b[%b%s%b%s]%b' \
    "$color" "$color" "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$DIM" "$(printf '%*s' "$empty" '' | tr ' ' '-')" "$RESET"
}

# ── help: a quick-start guide for this VPS (overrides the bash builtin) ─────────
# Defined for interactive shells so `help` shows how to deploy, reach Headlamp, etc.
help() {
  local ip domain
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  domain="mysite.com"  # replaced by setup.sh
  cat <<EOF

$(echo -e "${BOLD}${CYAN}K3s cluster — quick start${RESET}")

$(echo -e "${BOLD}1. Deploy an app from your laptop${RESET}")  (Dokku-style: just git push)
   In your project (needs a Dockerfile + helm-values.yaml):
     git remote add deploy deploy@${ip}:my-app
     git push deploy main
   The first push auto-creates the app; build logs stream back in your terminal.

$(echo -e "${BOLD}2. Open the Headlamp dashboard${RESET}")
     https://headlamp.${domain}
   Generate a login token:
     kubectl create token headlamp -n headlamp --duration=8760h

$(echo -e "${BOLD}3. Handy commands${RESET}")
     k get pods -A           # 'k' is aliased to kubectl
     helm rollback <app>     # undo a bad deploy (back to the previous release)
     kubectl logs -f job/build-<app>-<sha>   # follow a running build

$(echo -e "${DIM}Tip: this status screen prints on login — re-run it anytime with 'motd'.${RESET}")

EOF
}
# Re-run the status banner on demand.
alias motd='source /etc/profile.d/k8s-motd.sh'

echo ""
echo -e "${BOLD}${CYAN}── K3s Cluster Status ──────────────────────────────${RESET}"
echo -e "${DIM}Type 'help' for a quick start guide (deploy, Headlamp, tips).${RESET}"
echo ""

# ── System resources ───────────────────────────────────────────
echo -e "${BOLD}System${RESET}"

# Disk
disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ -n "$disk_pct" ]; then
  if [ "$disk_pct" -ge 90 ]; then
    disk_color="$RED"
  elif [ "$disk_pct" -ge 75 ]; then
    disk_color="$YELLOW"
  else
    disk_color="$GREEN"
  fi
  echo -e "  Disk:   $(bar "$disk_pct" "$disk_color") ${disk_color}${disk_usage}${RESET}"
fi

# RAM
read -r mem_total mem_used mem_avail <<< "$(free -h 2>/dev/null | awk '/^Mem:/ {print $2, $3, $7}')"
mem_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')
if [ -n "$mem_pct" ]; then
  if [ "$mem_pct" -ge 90 ]; then
    mem_color="$RED"
  elif [ "$mem_pct" -ge 75 ]; then
    mem_color="$YELLOW"
  else
    mem_color="$GREEN"
  fi
  echo -e "  RAM:    $(bar "$mem_pct" "$mem_color") ${mem_color}${mem_used} / ${mem_total} (${mem_pct}% used, ${mem_avail} available)${RESET}"
fi

# Load average
load=$(uptime 2>/dev/null | sed 's/.*load average: //')
if [ -n "$load" ]; then
  echo -e "  Load:   ${load}"
fi

# Uptime
up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
echo -e "  Uptime: ${up}"

echo ""

# ── Kubernetes ─────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  echo -e "  ${DIM}kubectl not found${RESET}"
  echo ""
  # shellcheck disable=SC2317  # `exit 0` is reached only if run directly, not sourced
  return 2>/dev/null || exit 0
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo -e "  ${RED}Cluster unreachable${RESET}"
  echo ""
  # shellcheck disable=SC2317  # `exit 0` is reached only if run directly, not sourced
  return 2>/dev/null || exit 0
fi

# Node status
echo -e "${BOLD}Nodes${RESET}"
kubectl get nodes --no-headers 2>/dev/null | while read -r name state _ age version; do
  if [[ "$state" == "Ready" ]]; then
    echo -e "  ${GREEN}●${RESET} ${name}  ${state}  ${DIM}${age}  ${version}${RESET}"
  else
    echo -e "  ${RED}●${RESET} ${name}  ${state}  ${DIM}${age}  ${version}${RESET}"
  fi
done
echo ""

# Pods needing attention (not Running/Completed/Succeeded)
echo -e "${BOLD}Pods requiring attention${RESET}"
problem_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '
  $4 !~ /^(Running|Completed|Succeeded)$/ { print }
  $4 == "Running" && $2 ~ /[0-9]+\/[0-9]+/ {
    split($2, a, "/");
    if (a[1] != a[2]) print
  }
')

if [ -z "$problem_pods" ]; then
  echo -e "  ${GREEN}All pods healthy${RESET}"
else
  echo "$problem_pods" | while read -r ns name ready state restarts age; do
    restart_count=$(echo "$restarts" | grep -o '^[0-9]*')
    if [ -n "$restart_count" ] && [ "$restart_count" -ge 5 ]; then
      echo -e "  ${RED}●${RESET} ${ns}/${name}  ${state}  ${RED}${restarts} restarts${RESET}  ${DIM}${age}${RESET}"
    else
      echo -e "  ${YELLOW}●${RESET} ${ns}/${name}  ${state}  ${restarts} restarts  ${DIM}${age}${RESET}"
    fi
  done
fi
echo ""

# Recent restarts (pods with high restart counts)
high_restart_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | awk '{
  restarts = $5 + 0;
  if (restarts >= 5) print $1, $2, $5
}')

if [ -n "$high_restart_pods" ]; then
  echo -e "${BOLD}${YELLOW}High restart counts${RESET}"
  echo "$high_restart_pods" | while read -r ns name restarts; do
    echo -e "  ${YELLOW}⟳${RESET} ${ns}/${name}  ${restarts} restarts"
  done
  echo ""
fi

# Certificates not ready
if kubectl api-resources --api-group=cert-manager.io &>/dev/null 2>&1; then
  expiring_certs=$(kubectl get certificates --all-namespaces --no-headers 2>/dev/null | awk '$3 != "True" {print $1, $2, $3}')
  if [ -n "$expiring_certs" ]; then
    echo -e "${BOLD}${YELLOW}Certificate issues${RESET}"
    echo "$expiring_certs" | while read -r ns name ready; do
      echo -e "  ${YELLOW}⚠${RESET} ${ns}/${name}  Ready=${ready}"
    done
    echo ""
  fi
fi

# PVC usage summary
echo -e "${BOLD}Storage (PVCs)${RESET}"
pvcs=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null)
if [ -z "$pvcs" ]; then
  echo -e "  ${DIM}No PVCs found${RESET}"
else
  echo "$pvcs" | while read -r ns name state _ capacity _ _ age; do
    if [[ "$state" == "Bound" ]]; then
      echo -e "  ${GREEN}●${RESET} ${ns}/${name}  ${capacity}  ${DIM}${state}${RESET}"
    else
      echo -e "  ${RED}●${RESET} ${ns}/${name}  ${capacity}  ${state}"
    fi
  done
fi
echo ""

# Helm releases
if command -v helm &>/dev/null; then
  echo -e "${BOLD}Helm releases${RESET}"
  releases=$(helm list --all-namespaces --no-headers 2>/dev/null)
  if [ -z "$releases" ]; then
    echo -e "  ${DIM}No releases${RESET}"
  else
    echo "$releases" | while read -r name ns revision _ state chart _; do
      if [[ "$state" == "deployed" ]]; then
        echo -e "  ${GREEN}●${RESET} ${name}  ${DIM}${ns}  rev ${revision}  ${chart}${RESET}"
      else
        echo -e "  ${YELLOW}●${RESET} ${name}  ${state}  ${DIM}${ns}  rev ${revision}${RESET}"
      fi
    done
  fi
  echo ""
fi

# Failed jobs (last 10)
failed_jobs=$(kubectl get jobs --all-namespaces --no-headers 2>/dev/null | awk '$3 == "0/1" || $4 ~ /BackoffLimitExceeded/ {print $1, $2, $5}' | tail -5)
if [ -n "$failed_jobs" ]; then
  echo -e "${BOLD}${RED}Failed jobs${RESET}"
  echo "$failed_jobs" | while read -r ns name age; do
    echo -e "  ${RED}✗${RESET} ${ns}/${name}  ${DIM}${age}${RESET}"
  done
  echo ""
fi

echo -e "${DIM}── $(date '+%Y-%m-%d %H:%M:%S') ──${RESET}"
echo ""
