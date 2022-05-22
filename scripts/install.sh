#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export PATH=/usr/local/bin:$PATH
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"

# install k3s server
: ${INSECURE_REGISTRY:=hub.k8s.li}
: ${K3S_EXEC_ARGS:="--disable-cloud-controller --disable-network-policy --flannel-backend=host-gw"}
curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_MIRROR=cn INSTALL_K3S_EXEC="${K3S_EXEC_ARGS}" sh -

# install goss and jq command
curl -sSfL https://github.com/aelsabbahy/goss/releases/latest/download/goss-linux-amd64 -o /usr/local/bin/goss
curl -sSfL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /usr/local/bin/jq
chmod +x /usr/local/bin/{goss,jq}

mkdir -p ${HOME}/.kube
cat /etc/rancher/k3s/k3s.yaml > ${HOME}/.kube/config
chmod 400 ${HOME}/.kube/config

# config insecure registry
cat << EOF > /etc/rancher/k3s/registries.yaml
configs:
  "${INSECURE_REGISTRY}":
    tls:
      insecure_skip_verify: true
EOF

systemctl restart k3s

cp -f ${SCRIPT_ROOT}/goss.yaml ${HOME}/.goss.yaml
cp -f ${SCRIPT_ROOT}/prepare.sh /usr/local/bin/prepare.sh
chmod +x /usr/local/bin/prepare.sh
while true; do
  if prepare.sh; then
    break
  fi
  echo "Waiting for service readiness"
  sleep 10
done

# install helm by k3s helm cli
find /var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.overlayfs -type f -name 'helm_v3' -exec ln -f {} /usr/local/bin/helm \;

# stop k3s server for for prevent it starting the garbage collection to delete images
systemctl stop k3s

# Ensure on next boot that network devices get assigned unique IDs.
sed -i '/^\(HWADDR\|UUID\)=/d' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null || true

# Clean up network interface persistence
rm -f /etc/udev/rules.d/70-persistent-net.rules
mkdir -p /etc/udev/rules.d/70-persistent-net.rules
rm -f /lib/udev/rules.d/75-persistent-net-generator.rules
rm -rf /dev/.udev/
find /var/log -type f -exec truncate --size=0 {} \;
rm -f /root/anaconda-ks.cfg /root/original-ks.cfg
rm -rf /tmp/* /var/tmp/*

# cleanup all blob files of registry download image
find /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content/blobs/sha256 -size +1M -type f -delete

# zero out the rest of the free space using dd, then delete the written file.
dd if=/dev/zero of=/EMPTY bs=4M status=progress || rm -f /EMPTY
# run sync so Packer doesn't quit too early, before the large file is deleted.
sync

yum clean all
