#!/usr/bin/env bash
# ============================================================================
# 92-registry.sh — private registry + node trust:
#   1. distribute the lab CA to every node's system trust store
#      (containerd verifies registry TLS against it), restart containerd
#   2. deploy the registry (TLS via cert-manager, Longhorn PVC, LB 10.20.0.210)
#   3. verify: API answers from the host AND containerd on a node can pull
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

REG_IP="10.20.0.210"
[[ -s "$STATE_DIR/lab-ca.crt" ]] || die "lab CA missing — run scripts/60-addons.sh first"

log "1/3 distributing lab CA to node trust stores (containerd restart, serial) ..."
for n in $ALL_NODES; do
  if nssh "$n" "test -f /usr/local/share/ca-certificates/k8slab-ca.crt" 2>/dev/null; then
    log "  $n: already trusted"
    continue
  fi
  nscp "$n" "$STATE_DIR/lab-ca.crt" /tmp/k8slab-ca.crt
  nssh "$n" "sudo cp /tmp/k8slab-ca.crt /usr/local/share/ca-certificates/k8slab-ca.crt && sudo update-ca-certificates >/dev/null && sudo systemctl restart containerd"
  sleep 3
  log "  $n: lab CA trusted, containerd restarted"
done

log "2/3 deploying registry at https://$REG_IP (cert: registry.k8s.lab + IP SAN) ..."
kubectl apply -f "$LAB_DIR/manifests/registry.yaml" >/dev/null
kubectl -n infra wait --for=condition=Ready certificate/registry-tls --timeout=180s >/dev/null
kubectl -n infra rollout status deploy/registry --timeout=600s >/dev/null
LB_IP="$(kubectl -n infra get svc registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
[[ "$LB_IP" == "$REG_IP" ]] || die "registry LB got $LB_IP instead of $REG_IP"

log "3/3 verification ..."
retry 12 5 curl -fsS --cacert "$STATE_DIR/lab-ca.crt" "https://$REG_IP/v2/" -o /dev/null \
  || die "registry API not answering from host"
log "  ✔ registry API answers from host (TLS verified against lab CA)"
# containerd-level pull check from a node: push a tiny image first? Not yet —
# nothing is pushed. Prove trust chain instead: TLS handshake from a node.
nssh w1 "curl -fsS https://$REG_IP/v2/ -o /dev/null" \
  || die "node w1 does not trust the registry TLS"
log "  ✔ node containerd trust chain OK (system CA store)"

stage_done registry
log "registry ready — push with ko/crane to $REG_IP/<repo> (docs/70)"
