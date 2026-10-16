#!/usr/bin/env bash
# ============================================================================
# 60-addons.sh — the platform layer on top of the cluster:
#
#   1. local-path-provisioner   default StorageClass (dynamic PVs)
#   2. metrics-server           kubectl top / HPA (verified kubelet TLS)
#   3. cert-manager + lab CA    cluster PKI (Gateway API integration on)
#   4. shared Gateway           Cilium Gateway API + wildcard TLS at .200
#   5. demo app (podinfo)       hello.k8s.lab through the gateway
#   6. Hubble UI route          hubble.k8s.lab through the gateway
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

# any kubelet-serving CSRs still pending (e.g. after a kubelet restart)?
approve_kubelet_csrs

log "1/6 local-path-provisioner $LOCAL_PATH_VERSION (default StorageClass) ..."
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" >/dev/null
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s >/dev/null

log "2/6 metrics-server (TLS-verified against kubelet serving certs) ..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-preferred-address-types=InternalIP}' \
  --wait --timeout 5m >/dev/null

log "3/6 cert-manager $CERT_MANAGER_VERSION (+ lab root CA) ..."
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true \
  --set-json 'config={"apiVersion":"controller.config.cert-manager.io/v1alpha1","kind":"ControllerConfiguration","enableGatewayAPI":true}' \
  --wait --timeout 5m >/dev/null
kubectl apply -f "$LAB_DIR/manifests/cert-manager-issuers.yaml" >/dev/null
kubectl wait --for=condition=Ready clusterissuer/lab-ca --timeout=180s >/dev/null
kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "$STATE_DIR/lab-ca.crt"
log "    lab CA exported to .state/lab-ca.crt (trust this on clients for https)"

log "4/6 shared Gateway (Cilium Gateway API) at $GATEWAY_IP ..."
export GATEWAY_IP
render "$LAB_DIR/manifests/gateway.yaml" "$GEN_DIR/gateway.yaml" GATEWAY_IP
kubectl apply -f "$GEN_DIR/gateway.yaml" >/dev/null
if ! kubectl -n infra wait --for=condition=Programmed gateway/lab-gateway --timeout=150s >/dev/null 2>&1; then
  # some Cilium versions don't honor Gateway spec.addresses — drop the pin and
  # rely on LB-IPAM ordering (first-free in the pool is .200 on a fresh lab)
  warn "gateway not Programmed with pinned address — retrying without spec.addresses"
  kubectl -n infra patch gateway lab-gateway --type=json \
    -p '[{"op":"remove","path":"/spec/addresses"}]' >/dev/null
  kubectl -n infra wait --for=condition=Programmed gateway/lab-gateway --timeout=180s >/dev/null
fi
GW_ADDR="$(kubectl -n infra get gateway lab-gateway -o jsonpath='{.status.addresses[0].value}')"
[[ "$GW_ADDR" == "$GATEWAY_IP" ]] \
  || die "Gateway got $GW_ADDR instead of pinned $GATEWAY_IP — check CiliumLoadBalancerIPPool"
kubectl -n infra wait --for=condition=Ready certificate/lab-wildcard-tls --timeout=300s >/dev/null \
  || warn "wildcard cert not Ready yet (cert-manager still working?)"

log "5/6 demo app: podinfo -> http(s)://hello.k8s.lab ..."
export PODINFO_VERSION
render "$LAB_DIR/manifests/demo-podinfo.yaml" "$GEN_DIR/demo-podinfo.yaml" PODINFO_VERSION
kubectl apply -f "$GEN_DIR/demo-podinfo.yaml" >/dev/null
kubectl -n default rollout status deploy/podinfo --timeout=300s >/dev/null

log "6/6 Hubble UI route -> http://hubble.k8s.lab ..."
kubectl apply -f "$LAB_DIR/manifests/hubble-route.yaml" >/dev/null

log "smoke test through the gateway ..."
retry 12 5 curl -fsS --max-time 5 "http://hello.k8s.lab/" -o /dev/null \
  || die "gateway smoke test failed (curl http://hello.k8s.lab)"
log "gateway answers: $(curl -fsS --max-time 5 http://hello.k8s.lab/ | jq -r '"\(.hostname) — podinfo \(.version)"')"

stage_done addons
log "platform complete — run scripts/70-verify.sh for the full battery"
