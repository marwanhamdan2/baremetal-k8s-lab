#!/usr/bin/env bash
# ============================================================================
# 90-storage.sh — production-grade storage layer:
#
#   1. node prereq: open-iscsi (Longhorn's data path)
#   2. Longhorn (helm) -> DEFAULT StorageClass, 2 replicas across workers
#   3. CSI snapshot support: external-snapshotter CRDs + snapshot-controller
#      (kubeadm clusters don't ship these!) + a default VolumeSnapshotClass
#   4. full CSI verification: write -> snapshot -> restore -> read
#
# local-path stays installed (observability PVCs already live there) but
# loses the default annotation. Docs: docs/15-storage-csi.md
# ============================================================================
set -Eeuo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

log "1/4 installing open-iscsi on all nodes (Longhorn prereq) ..."
for n in $ALL_NODES; do
  nssh "$n" "command -v iscsiadm >/dev/null || { sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq open-iscsi >/dev/null; }; sudo systemctl enable --now iscsid >/dev/null 2>&1; echo \"  \$(hostname): iscsid \$(systemctl is-active iscsid)\"" &
done
wait

log "2/4 installing Longhorn (this pulls ~1GB of images, be patient) ..."
helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null
helm repo update longhorn >/dev/null
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  -f "$LAB_DIR/config/longhorn-values.yaml" \
  --wait --timeout 20m >/dev/null
# exactly one default StorageClass: demote local-path
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=false --overwrite >/dev/null
kubectl get storageclass

log "3/4 CSI snapshot machinery (external-snapshotter) ..."
SNAP_VER="$(curl -fsSI https://github.com/kubernetes-csi/external-snapshotter/releases/latest | grep -i '^location:' | sed 's#.*/tag/##' | tr -d '\r\n')"
log "  external-snapshotter $SNAP_VER"
BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/$SNAP_VER"
kubectl apply -f "$BASE/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml" \
              -f "$BASE/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml" \
              -f "$BASE/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml" >/dev/null
kubectl apply -f "$BASE/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" \
              -f "$BASE/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" >/dev/null
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=300s >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap   # in-cluster snapshot; WITHOUT this Longhorn treats CSI
               # snapshots as BACKUPS and hangs unless a backup target exists
EOF

log "4/4 CSI verification: provision -> write -> snapshot -> restore -> read ..."
kubectl create ns csi-smoke --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'EOF' | kubectl -n csi-smoke apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: writer }
spec:
  restartPolicy: Never
  containers:
    - name: w
      image: busybox:1.36
      command: ["sh", "-c", "echo lab-data-$(date +%s) > /data/proof && cat /data/proof && sync"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes: [{ name: v, persistentVolumeClaim: { claimName: smoke } }]
EOF
kubectl -n csi-smoke wait --for=jsonpath='{.status.phase}'=Succeeded pod/writer --timeout=300s >/dev/null
PROOF="$(kubectl -n csi-smoke logs writer)"
log "  wrote: $PROOF"

cat <<'EOF' | kubectl -n csi-smoke apply -f - >/dev/null
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: smoke-snap }
spec:
  volumeSnapshotClassName: longhorn
  source: { persistentVolumeClaimName: smoke }
EOF
retry 30 5 bash -c "kubectl -n csi-smoke get volumesnapshot smoke-snap -o jsonpath='{.status.readyToUse}' | grep -q true" \
  || die "snapshot never became ready"
log "  snapshot readyToUse"

cat <<'EOF' | kubectl -n csi-smoke apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: restored }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  dataSource:
    name: smoke-snap
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
---
apiVersion: v1
kind: Pod
metadata: { name: reader }
spec:
  restartPolicy: Never
  containers:
    - name: r
      image: busybox:1.36
      command: ["sh", "-c", "cat /data/proof"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes: [{ name: v, persistentVolumeClaim: { claimName: restored } }]
EOF
kubectl -n csi-smoke wait --for=jsonpath='{.status.phase}'=Succeeded pod/reader --timeout=300s >/dev/null
RESTORED="$(kubectl -n csi-smoke logs reader)"
[[ "$RESTORED" == "$PROOF" ]] || die "restore mismatch: '$RESTORED' != '$PROOF'"
log "  restored from snapshot, content verified: $RESTORED"
kubectl delete ns csi-smoke --wait=false >/dev/null

stage_done storage
log "storage layer complete — Longhorn is the default StorageClass with working snapshots"
