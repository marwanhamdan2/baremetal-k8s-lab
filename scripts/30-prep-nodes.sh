#!/usr/bin/env bash
# ============================================================================
# 30-prep-nodes.sh — run node/prep.sh on all 6 nodes in parallel.
# Logs: .state/logs/prep-<node>.log
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

declare -A pids
for n in $ALL_NODES; do
  (
    nscp "$n" "$LAB_DIR/scripts/node/prep.sh" /tmp/prep.sh
    nssh "$n" "sudo K8S_MINOR=$K8S_MINOR PAUSE_IMAGE=$PAUSE_IMAGE bash /tmp/prep.sh"
  ) > "$LOG_DIR/prep-$n.log" 2>&1 &
  pids[$n]=$!
  log "prep started on $n (pid ${pids[$n]})"
done

fail=0
for n in $ALL_NODES; do
  if wait "${pids[$n]}"; then
    log "prep OK: $n — $(tail -1 "$LOG_DIR/prep-$n.log")"
  else
    warn "prep FAILED on $n — see $LOG_DIR/prep-$n.log"
    fail=1
  fi
done
[[ $fail -eq 0 ]] || die "node prep failed on at least one node"

stage_done prep
log "all 6 nodes prepped (containerd + kubeadm ready)"
