# netplan v2, rendered per node (vars: MAC_MGMT, MAC_CLUSTER, MGMT_IP,
# CLUSTER_IP, MGMT_GW, LAB_DOMAIN). NICs are matched by MAC (deterministic,
# set on the libvirt domain) and renamed eth0/eth1.
#
#   eth0 = mgmt   (NAT, default route + DNS -> internet egress, SSH)
#   eth1 = cluster (routed, NO gateway     -> all Kubernetes traffic)
version: 2
ethernets:
  eth0:
    match: { macaddress: "${MAC_MGMT}" }
    set-name: eth0
    addresses: ["${MGMT_IP}/24"]
    routes: [{ to: default, via: "${MGMT_GW}" }]
    nameservers:
      addresses: ["${MGMT_GW}"]
      search: ["${LAB_DOMAIN}"]
  eth1:
    match: { macaddress: "${MAC_CLUSTER}" }
    set-name: eth1
    addresses: ["${CLUSTER_IP}/24"]
