#!/usr/bin/env bash
# ============================================================================
# 10-networks.sh — define + start the two libvirt networks (the rack fabric).
#
#   k8s-mgmt    10.10.0.0/24  NAT     bridge virbr-k8smg   (OOB mgmt, internet)
#   k8s-cluster 10.20.0.0/24  ROUTED  bridge virbr-k8scl   (all k8s traffic)
#
# mgmt runs dnsmasq: DHCP for ad-hoc VMs + authoritative DNS for *.k8s.lab.
# cluster is routed (no NAT): host acts as the core router, so the host and
# (with a static route) other LAN devices reach node/VIP/LB IPs directly.
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

dns_hosts_xml() {
  local n
  printf "    <host ip='%s'><hostname>%s</hostname></host>\n" "$API_VIP" "$API_FQDN"
  printf "    <host ip='%s'><hostname>hello.%s</hostname><hostname>hubble.%s</hostname><hostname>grafana.%s</hostname></host>\n" \
    "$GATEWAY_IP" "$LAB_DOMAIN" "$LAB_DOMAIN" "$LAB_DOMAIN"
  for n in $ALL_NODES; do
    printf "    <host ip='%s'><hostname>%s.%s</hostname><hostname>%s</hostname></host>\n" \
      "$(cluster_ip "$n")" "$n" "$LAB_DOMAIN" "$n"
  done
}

cat > "$GEN_DIR/net-mgmt.xml" <<EOF
<network>
  <name>${MGMT_NET}</name>
  <bridge name='${MGMT_BR}' stp='on' delay='0'/>
  <forward mode='nat'/>
  <domain name='${LAB_DOMAIN}' localOnly='yes'/>
  <dns>
$(dns_hosts_xml)
  </dns>
  <ip address='${MGMT_GW}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${MGMT_DHCP_START}' end='${MGMT_DHCP_END}'/>
    </dhcp>
  </ip>
</network>
EOF

cat > "$GEN_DIR/net-cluster.xml" <<EOF
<network>
  <name>${CLUSTER_NET}</name>
  <bridge name='${CLUSTER_BR}' stp='on' delay='0'/>
  <forward mode='route'/>
  <ip address='${CLUSTER_HOST_IP}' netmask='255.255.255.0'/>
</network>
EOF

ensure_net() {
  local name="$1" xml="$2"
  if vsh net-info "$name" &>/dev/null; then
    log "network $name already defined — leaving as-is (use --force to recreate)"
  else
    log "defining network $name"
    vsh net-define "$xml"
  fi
  vsh net-autostart "$name" >/dev/null 2>&1 || true
  net_active "$name" || vsh net-start "$name"
}

if [[ "${1:-}" == "--force" ]]; then
  for net in "$MGMT_NET" "$CLUSTER_NET"; do
    vsh net-destroy "$net" &>/dev/null || true
    vsh net-undefine "$net" &>/dev/null || true
  done
fi

ensure_net "$MGMT_NET" "$GEN_DIR/net-mgmt.xml"
ensure_net "$CLUSTER_NET" "$GEN_DIR/net-cluster.xml"

log "networks up:"
vsh net-list --all
stage_done networks
