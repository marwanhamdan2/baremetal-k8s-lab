# kubeadm init configuration (rendered by scripts/40-init-cluster.sh)
# API version v1beta4 = kubeadm >= 1.31 config schema.
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CP1_IP}"       # cp1 on the CLUSTER network (eth1)
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip                   # register on the cluster net, not mgmt
      value: "${CP1_IP}"
skipPhases:
  - addon/kube-proxy                  # Cilium fully replaces kube-proxy (eBPF)
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: ${LAB_NAME}
kubernetesVersion: "${K8S_VER_EXACT}"
controlPlaneEndpoint: "${API_FQDN}:6443"   # the kube-vip VIP — the HA entrypoint
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SVC_CIDR}"
  dnsDomain: cluster.local
apiServer:
  certSANs:                           # extra names the API cert must be valid for
${CERT_SANS}
---
# Applies to every kubelet in the cluster (stored in the kubelet-config CM).
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Prod-correct kubelet serving TLS: kubelets request serving certs from the
# cluster CA (CSRs must be approved — see labctl approve-certs). This lets
# metrics-server & co. verify kubelet TLS instead of --kubelet-insecure-tls.
serverTLSBootstrap: true
rotateCertificates: true
