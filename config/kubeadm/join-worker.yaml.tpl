# kubeadm join configuration for a WORKER node
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${API_FQDN}:6443"
    token: "${TOKEN}"
    caCertHashes: ["${CA_HASH}"]
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${NODE_IP}"
