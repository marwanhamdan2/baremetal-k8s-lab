#!/usr/bin/env bash
# Shared helpers for all lab scripts. Scripts source this; it sources lab.env.
set -Eeuo pipefail

LAB_DIR="${LAB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../config/lab.env
. "$LAB_DIR/config/lab.env"

STATE_DIR="$LAB_DIR/.state"
LOG_DIR="$STATE_DIR/logs"
GEN_DIR="$LAB_DIR/generated"
CACHE_DIR="$LAB_DIR/.cache"
mkdir -p "$STATE_DIR" "$LOG_DIR" "$GEN_DIR" "$CACHE_DIR"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_off=$'\e[0m'
log()  { printf '%s[%s]%s %s\n' "$c_grn" "$(date +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

ALL_NODES="$CP_NODES $WORKER_NODES"

node_octet() {
  case "$1" in
    cp1) echo 11 ;; cp2) echo 12 ;; cp3) echo 13 ;;
    w1)  echo 21 ;; w2)  echo 22 ;; w3)  echo 23 ;;
    *) die "unknown node: $1" ;;
  esac
}
mgmt_ip()     { echo "10.10.0.$(node_octet "$1")"; }
cluster_ip()  { echo "10.20.0.$(node_octet "$1")"; }
mac_mgmt()    { printf '52:54:00:10:00:%02x' "$(node_octet "$1")"; }
mac_cluster() { printf '52:54:00:20:00:%02x' "$(node_octet "$1")"; }
vm_name()     { echo "$VM_PREFIX-$1"; }
is_cp()       { [[ " $CP_NODES " == *" $1 "* ]]; }
node_vcpus()  { if is_cp "$1"; then echo "$CP_VCPUS"; else echo "$W_VCPUS"; fi; }
node_ram()    { if is_cp "$1"; then echo "$CP_RAM_MB"; else echo "$W_RAM_MB"; fi; }
node_disk()   { if is_cp "$1"; then echo "$CP_DISK_GB"; else echo "$W_DISK_GB"; fi; }

# Run a command with libvirt group privileges. Works immediately after
# 00-host-setup.sh, before the user has re-logged-in to pick up the group.
lv() {
  if id -nG | grep -qw libvirt; then "$@"
  else sg libvirt -c "$(printf '%q ' "$@")"
  fi
}
vsh() { lv virsh --connect qemu:///system "$@"; }

# state checks via capture, NOT `virsh ... | grep -q` — grep -q's early exit
# SIGPIPEs virsh, and with pipefail the healthy path looks like a failure.
net_active()   { [[ "$(vsh net-info "$1" 2>/dev/null)" == *"Active:"*"yes"* ]]; }
pool_running() { [[ "$(vsh pool-info "$1" 2>/dev/null)" == *"State:"*"running"* ]]; }
vm_state() {
  local s
  s="$(vsh domstate "$(vm_name "$1")" 2>/dev/null || true)"
  s="${s%%$'\n'*}"
  echo "${s:-undefined}"
}

SSH_OPTS=(-i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$STATE_DIR/known_hosts"
  -o ConnectTimeout=8 -o LogLevel=ERROR)
nssh() { local n="$1"; shift; ssh "${SSH_OPTS[@]}" "$SSH_USER@$(mgmt_ip "$n")" "$@"; }
nscp() { local n="$1" src="$2" dst="$3"; scp -q "${SSH_OPTS[@]}" "$src" "$SSH_USER@$(mgmt_ip "$n"):$dst"; }

wait_ssh() {
  local n="$1" timeout="${2:-420}" i=0
  log "waiting for SSH on $n ($(mgmt_ip "$n")) ..."
  until nssh "$n" true 2>/dev/null; do
    sleep 5; i=$((i + 5))
    [[ $i -ge $timeout ]] && die "SSH to $n not up after ${timeout}s (debug: ./labctl console $n)"
  done
}

retry() {
  local tries="$1" delay="$2" i; shift 2
  for ((i = 1; i <= tries; i++)); do "$@" && return 0; [[ $i -lt $tries ]] && sleep "$delay"; done
  return 1
}

# render TEMPLATE OUT VAR1 VAR2...  — envsubst restricted to the listed
# (exported) variables so stray $ in templates is never clobbered.
render() {
  local tpl="$1" out="$2" v vars=""; shift 2
  for v in "$@"; do vars+="\${$v} "; done
  envsubst "$vars" < "$tpl" > "$out"
}

stage_done() { touch "$STATE_DIR/stage.$1"; }
stage_ok()   { [[ -f "$STATE_DIR/stage.$1" ]]; }

lan_iface() { ip route show default 2>/dev/null | awk '{print $5; exit}'; }
lan_ip()    { ip -4 -o addr show "$(lan_iface)" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# Approve pending kubelet-serving CSRs (needed because we run with
# serverTLSBootstrap=true — the prod-correct way to get verified kubelet TLS).
approve_kubelet_csrs() {
  local pending
  pending=$(kubectl get csr -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.signerName=="kubernetes.io/kubelet-serving")
             | select((.status.conditions // []) | length == 0) | .metadata.name')
  [[ -n "$pending" ]] && kubectl certificate approve $pending
  return 0
}
