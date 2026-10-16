#!/usr/bin/env bash
# ============================================================================
# 70-verify.sh — end-to-end verification battery.
#   ./scripts/70-verify.sh              full battery
#   ./scripts/70-verify.sh --failover   + live HA drill (pauses cp1!)
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

pass=0; fail=0
chk() {  # chk "description" cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \e[32m✔\e[0m %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  \e[31m✘\e[0m %s\n' "$desc"; fail=$((fail+1))
  fi
}

vms_running() { local n; for n in $ALL_NODES; do [[ "$(vm_state "$n")" == running ]] || return 1; done; }

log "── infrastructure ─────────────────────────────────────────────"
chk "6 VMs running"                       vms_running
chk "mgmt network active"                 net_active "$MGMT_NET"
chk "cluster network active"              net_active "$CLUSTER_NET"
chk "host can SSH every node"             bash -c "for n in $ALL_NODES; do . $LAB_DIR/lib/common.sh; nssh \$n true || exit 1; done"

log "── control plane / HA ─────────────────────────────────────────"
chk "API reachable via VIP $API_VIP"      kubectl --request-timeout=5s get --raw /readyz
chk "all 6 nodes Ready"                   bash -c "[[ \$(kubectl get nodes --no-headers | grep -cw Ready) -eq 6 ]]"
chk "3 etcd members"                      bash -c "[[ \$(kubectl -n kube-system get pods -l component=etcd --no-headers | grep -c Running) -eq 3 ]]"
chk "3 kube-apiservers"                   bash -c "[[ \$(kubectl -n kube-system get pods -l component=kube-apiserver --no-headers | grep -c Running) -eq 3 ]]"
chk "kube-vip on all CPs"                 bash -c "[[ \$(kubectl -n kube-system get pods --no-headers | grep -c 'kube-vip.*Running') -eq 3 ]]"
chk "NO kube-proxy (replaced by Cilium)"  bash -c "! kubectl -n kube-system get ds kube-proxy 2>/dev/null"

log "── networking (Cilium) ────────────────────────────────────────"
chk "cilium agents healthy on 6 nodes"    bash -c "[[ \$(kubectl -n kube-system get ds cilium -o jsonpath='{.status.numberReady}') -eq 6 ]]"
chk "VXLAN tunnel mode active"            bash -c "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -qi 'vxlan'"
chk "hubble relay up"                     bash -c "kubectl -n kube-system rollout status deploy/hubble-relay --timeout=10s"
chk "coredns resolves"                    bash -c "kubectl run -q dnstest --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local"

log "── services / gateway ─────────────────────────────────────────"
chk "gateway Programmed at $GATEWAY_IP"   bash -c "[[ \$(kubectl -n infra get gateway lab-gateway -o jsonpath='{.status.addresses[0].value}') == $GATEWAY_IP ]]"
chk "HTTP  hello.k8s.lab via gateway"     curl -fsS --max-time 5 http://hello.k8s.lab/ -o /dev/null
chk "HTTPS hello.k8s.lab (lab CA trust)"  curl -fsS --max-time 5 --cacert "$STATE_DIR/lab-ca.crt" https://hello.k8s.lab/ -o /dev/null
chk "Hubble UI via gateway"               curl -fsS --max-time 5 http://hubble.k8s.lab/ -o /dev/null
chk "metrics: kubectl top nodes"          kubectl top nodes

log "── LAN exposure ───────────────────────────────────────────────"
chk "nftables DNAT table present"         bash -c "command -v nft >/dev/null && sudo -n nft list table inet k8slab 2>/dev/null || nft list table inet k8slab 2>/dev/null || [[ -f /etc/nftables.d/k8slab.nft ]]"
LAN_IP="$(lan_ip || true)"
[[ -n "$LAN_IP" ]] && log "  from another LAN device: https://$LAN_IP:6443 (API), http://$LAN_IP (gateway), https://$LAN_IP:9090 (cockpit)"

# ---------------------------------------------------------------- failover
if [[ "${1:-}" == "--failover" ]]; then
  log "── HA FAILOVER DRILL: pausing cp1 (current VIP holder candidate) ──"
  vsh suspend "$(vm_name cp1)"
  t0=$(date +%s)
  if retry 20 3 kubectl --request-timeout=3s get nodes >/dev/null 2>&1; then
    log "  ✔ API stayed available via VIP — failover took ≤$(( $(date +%s) - t0 ))s (ARP moved to cp2/cp3)"
    pass=$((pass+1))
  else
    warn "  ✘ API did not recover within 60s"; fail=$((fail+1))
  fi
  vsh resume "$(vm_name cp1)"
  log "  cp1 resumed; etcd re-syncs automatically"
fi

echo
log "verification: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
