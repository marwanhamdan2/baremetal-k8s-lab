#cloud-config
# Rendered per node by scripts/20-create-vms.sh (vars: NODE, LAB_DOMAIN,
# SSH_USER, SSH_PUB, ETC_HOSTS). OS-level identity only — Kubernetes node
# preparation happens transparently in scripts/node/prep.sh over SSH.
hostname: ${NODE}
fqdn: ${NODE}.${LAB_DOMAIN}
manage_etc_hosts: false

users:
  - name: ${SSH_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUB}

ssh_pwauth: false
timezone: Etc/UTC
package_update: false
packages:
  - qemu-guest-agent

write_files:
  # Static name resolution for the whole rack (mirrors a DC-local DNS zone;
  # libvirt's dnsmasq on the mgmt network serves the same records).
  - path: /etc/hosts
    permissions: "0644"
    content: |
${ETC_HOSTS}

runcmd:
  - systemctl enable --now qemu-guest-agent
