# ============================================================================
# Cilium helm values (rendered by scripts/50-cilium.sh; vars: API_VIP, POD_CIDR)
#
# Design choices (see docs/10-networking.md for the full story):
#   - kube-proxy REPLACED by eBPF (kubeadm skipped the kube-proxy addon)
#   - VXLAN overlay between nodes over the cluster network (eth1)
#   - LB-IPAM + L2 announcements = on-prem LoadBalancer services (no MetalLB)
#   - Gateway API implementation enabled (the "API gateway" of the lab)
#   - Hubble = deep network observability (flows, service map, UI)
# ============================================================================
cluster:
  name: k8slab
  id: 1

# --- kube-proxy replacement --------------------------------------------------
kubeProxyReplacement: true
# with no kube-proxy, the agents need a stable API endpoint outside the
# cluster's own service network -> the kube-vip VIP:
k8sServiceHost: "${API_VIP}"
k8sServicePort: 6443

# --- datapath: VXLAN overlay -------------------------------------------------
routingMode: tunnel
tunnelProtocol: vxlan          # UDP 8472 between node eth1 IPs (10.20.0.0/24)
# use iptables-based egress masquerade: correct across BOTH node NICs
# (pod -> internet leaves via eth0/mgmt, pod -> pod rides VXLAN via eth1)
bpf:
  masquerade: false
devices: "eth+"                # attach eBPF to eth0+eth1 (NodePort, L2, host fw)

# --- pod IPAM ---------------------------------------------------------------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList: ["${POD_CIDR}"]
    clusterPoolIPv4MaskSize: 24   # one /24 per node

# --- on-prem LoadBalancer (replaces MetalLB) --------------------------------
l2announcements:
  enabled: true                # answer ARP for LB IPs on the cluster net
externalIPs:
  enabled: true
# L2 announcements lease-churn needs a higher client rate limit (per docs)
k8sClientRateLimit:
  qps: 32
  burst: 64

# --- API gateway (Gateway API implementation) -------------------------------
gatewayAPI:
  enabled: true
envoy:
  enabled: true                # dedicated per-node Envoy DaemonSet (L7 proxy)
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true

# --- observability -----------------------------------------------------------
# agent/operator/Hubble/Envoy metrics + ServiceMonitors (picked up by the
# Prometheus Operator once scripts/80-observability.sh has run)
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true

hubble:
  enabled: true
  relay:
    enabled: true
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
  ui:
    enabled: true
  metrics:
    enabled: [dns, drop, tcp, flow, icmp, httpV2]
    serviceMonitor:
      enabled: true

operator:
  replicas: 2                  # HA operator (anti-affinity across nodes)
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
rollOutCiliumPods: true
