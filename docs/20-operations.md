# Operations runbook

Day-2 operations, ordered from daily to disaster. Everything here is a
transferable on-prem skill — the lab just makes failure cheap.

## Daily lifecycle

```bash
./labctl start      # CPs first (etcd quorum forms), then workers
./labctl stop       # workers first (graceful, guest-agent), CPs last
./labctl status     # VMs + nodes + endpoints at a glance
./labctl doctor     # health checks with fix hints
```

Order matters: etcd needs 2/3 members to serve writes — starting workers
before the control plane just makes kubelets retry, but stopping CPs first
while workers drain would strand in-flight state. The lab **autostarts with
the host** (`./labctl autostart on|off|status`): at boot all VMs start
together and the cluster converges on its own (exactly what happens when a
real rack regains power) — expect the API ~1-2 min after login. On host
shutdown, libvirt-guests shuts the VMs down gracefully (clean etcd stop).

## Snapshots — your reset button

Offline, internal qcow2 snapshots of **all 6 VMs together** (a consistent
cluster needs consistent etcd + node state — never snapshot a lone CP):

```bash
./labctl snapshot create baseline     # taken once at initial bring-up
./labctl snapshot create pre-upgrade  # before anything scary
./labctl reset                        # = snapshot restore baseline
```

## Scaling out — add a worker `w4`

The full on-prem "new server arrives" flow (~5 min):

1. Add `w4` to `WORKER_NODES` in [config/lab.env](../config/lab.env) and give
   it an octet in `node_octet()` in [lib/common.sh](../lib/common.sh) (e.g. `w4) echo 24`).
2. Provision + prep: `./scripts/20-create-vms.sh && ./scripts/30-prep-nodes.sh`
   (both skip existing nodes).
3. Mint a join config on the host and join:
   ```bash
   ./labctl ssh cp1 "sudo kubeadm token create --print-join-command"
   # render config/kubeadm/join-worker.yaml.tpl with the new token/hash, or
   # simply run the printed command on w4 with --node-ip 10.20.0.24 appended
   ./labctl approve-certs        # its kubelet-serving CSR
   ```
4. `kubectl get nodes` → w4 Ready (Cilium lands via DaemonSet automatically).

Removing: `kubectl drain w4 --ignore-daemonsets --delete-emptydir-data`,
`kubectl delete node w4`, then `virsh undefine k8s-w4 --remove-all-storage`.

## Upgrading Kubernetes (the 1.35 → 1.36 exercise)

The lab intentionally runs n-1 so you can practice a real minor upgrade.
Sequence — one node at a time, CPs first, **snapshot before**:

```bash
./labctl snapshot create pre-1.36
# on cp1: move the package train to v1.36, then:
./labctl ssh cp1 "sudo apt-mark unhold kubeadm && \
  sudo sed -i 's/v1.35/v1.36/' /etc/apt/sources.list.d/kubernetes.list && \
  sudo apt-get update -q && sudo apt-get install -y kubeadm && sudo apt-mark hold kubeadm"
./labctl ssh cp1 "sudo kubeadm upgrade plan"          # READ this output
./labctl ssh cp1 "sudo kubeadm upgrade apply v1.36.x"
# then kubelet on cp1:
kubectl drain cp1 --ignore-daemonsets
./labctl ssh cp1 "sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet kubectl && \
  sudo apt-mark hold kubelet kubectl && sudo systemctl restart kubelet"
kubectl uncordon cp1
# cp2/cp3: same but `kubeadm upgrade node` instead of `apply`; then workers
```

Checks between every node: `kubectl get nodes` (versions mixed is fine
mid-upgrade — skew policy allows kubelet n-3), `cilium status`. Check the
Cilium/k8s support matrix before jumping; bump `K8S_MINOR` in `lab.env`
afterwards so future nodes install 1.36.

## etcd — backup and restore

```bash
./labctl etcd-backup            # snapshot via etcd-cp1 → backups/etcd-<ts>.db
```

Restore drill (destructive — snapshot the lab first!): stop kube-apiserver
static pods on all CPs, `etcdutl snapshot restore` the file into a fresh data
dir on cp1 with `--initial-cluster` of only cp1, start, then re-join cp2/cp3
by wiping `/var/lib/etcd` and re-running `kubeadm join --control-plane`.
The muscle memory you want: **quorum loss is recovered from backup, not by
resurrecting members**.

## Certificates

```bash
./labctl ssh cp1 "sudo kubeadm certs check-expiration"
./labctl ssh cp1 "sudo kubeadm certs renew all"     # then restart static pods
./labctl approve-certs                              # kubelet serving rotations
```

- kubeadm client/serving certs live 1 year; `renew all` + restart handles it.
- kubelet **serving** certs (serverTLSBootstrap) rotate ~monthly and need CSR
  approval — that's `./labctl approve-certs`, or deploy
  `postfinance/kubelet-csr-approver` to automate approval by policy.
- Changing the API cert SANs (e.g. your laptop's LAN IP changed): edit the
  `certSANs` in [config/kubeadm/init-config.yaml.tpl](../config/kubeadm/init-config.yaml.tpl), then on cp1:
  `sudo rm /etc/kubernetes/pki/apiserver.{crt,key} && sudo kubeadm init phase certs apiserver --config <rendered cfg>` and restart the apiserver pod.

## Failure drills

| Drill | How | What you should observe |
|---|---|---|
| CP failover | `./scripts/70-verify.sh --failover` (or `virsh suspend k8s-cp1`) | VIP re-ARPs to another CP in seconds; API never needs reconfig |
| etcd quorum loss | suspend cp1 **and** cp2 | API writes fail, pods keep running; resume → self-heals |
| Worker death | `virsh destroy k8s-w2` | pods rescheduled after ~5 min (default tolerations); `labctl start` heals |
| Drain/maintenance | `kubectl drain w1 --ignore-daemonsets` | podinfo replicas shift; gateway keeps serving |
| Network partition | `virsh domif-setlink k8s-w3 52:54:00:20:00:17 down` | node NotReady, Cilium health degraded; `…up` restores |
| LB failover | kill the node holding the .200 lease | new leaseholder, gratuitous ARP — watch `./labctl sniff arp` |

## Rebuild from scratch

```bash
./labctl destroy          # VMs (asks about networks); host packages stay
./labctl up               # ~15 min back to a verified cluster
```

`config/lab.env` is the only file you ever tune; everything downstream is
rendered from it.
