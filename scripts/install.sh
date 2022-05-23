#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

export PATH=/usr/local/bin:$PATH
SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="${SCRIPT_ROOT}/../resources"

: ${ARGO_VERSION:=0.15.3}
: ${INSECURE_REGISTRY:=hub.k8s.li}
: ${K3S_EXEC_ARGS:="-disable=local-storage,metrics-server --disable-cloud-controller --disable-network-policy --flannel-backend=host-gw --log=/var/log/k3s.log"}

# create iso storage dir
mkdir -p /data/iso
chmod 777 /data/iso

function install_k3s() {
  mkdir -p /etc/rancher/k3s
  # config insecure registry
  cat << EOF > /etc/rancher/k3s/registries.yaml
configs:
  "${INSECURE_REGISTRY}":
    tls:
      insecure_skip_verify: true
EOF
  curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_MIRROR=cn INSTALL_K3S_EXEC="${K3S_EXEC_ARGS}" sh -

  # install goss and jq command
  curl -sSfL https://github.com/aelsabbahy/goss/releases/latest/download/goss-linux-amd64 -o /usr/local/bin/goss
  curl -sSfL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /usr/local/bin/jq
  chmod +x /usr/local/bin/{goss,jq}
  mkdir -p ${HOME}/.goss
  cp -rf ${SCRIPT_ROOT}/goss/* ${HOME}/.goss/
  cp -f ${SCRIPT_ROOT}/prepare.sh /usr/local/bin/prepare.sh
  chmod +x /usr/local/bin/prepare.sh

  # wait for k3s cluster to be ready
  IP_ADDRESS=$(ip r get 1 | sed "s/ uid.*//g" | awk '{print $NF}' | head -n1)
  while true; do
    if goss --vars-inline "ip_address: ${IP_ADDRESS}" -g ${HOME}/.goss/k3s.yaml validate --retry-timeout=10s; then
      break
    fi
    echo "Waiting for k3s cluster to be ready..."
    sleep 10
  done

  # copy k3s kubeconfig to ${HOME}/.kube/config
  mkdir -p ${HOME}/.kube
  cat /etc/rancher/k3s/k3s.yaml > ${HOME}/.kube/config
  chmod 400 ${HOME}/.kube/config
}

function deploy_resources() {
  # install helm by k3s helm cli
  find /var/lib/rancher/k3s/agent/containerd/io.containerd.snapshotter.v1.overlayfs -type f -name 'helm_v3' -exec ln -f {} /usr/local/bin/helm \;

  # create filebrowser deployment and clusterrolebinding
  kubectl apply -f ${RESOURCES_DIR}/manifests

  # helm install argo-workflow release
  helm repo add argo https://argoproj.github.io/argo-helm
  helm template --version ${ARGO_VERSION} -f ${RESOURCES_DIR}/values/argo-workflow.yaml argo/argo-workflows | grep 'quay.io' | awk '{print $NF}' | tr -d '"' | xargs -L1 -I {} -t crictl pull {}
  helm upgrade --cleanup-on-fail --atomic --wait --wait-for-jobs -i argo-workflow --version ${ARGO_VERSION} -f resources/values/argo-workflow.yaml argo/argo-workflows

  # pull redfish-esxi-os-installer container image
  kubectl create -f ${RESOURCES_DIR}/workflow --dry-run=client -o yaml | sed -n 's/image://p' | tr -d ' ' | xargs -L1 -I {} crictl pull {}

  while true; do
    if prepare.sh; then
      break
    fi
    echo "Waiting for service readiness"
    sleep 10
  done
}

function cleanup(){
  # stop k3s server for for prevent it starting the garbage collection to delete images
  systemctl stop k3s

  # Ensure on next boot that network devices get assigned unique IDs.
  sed -i '/^\(HWADDR\|UUID\)=/d' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null || true

  # Clean up network interface persistence
  find /var/log -type f -exec truncate --size=0 {} \;
  rm -rf /tmp/* /var/tmp/*

  # cleanup all blob files of registry download image
  find /var/lib/rancher/k3s/agent/containerd/io.containerd.content.v1.content/blobs/sha256 -size +1M -type f -delete

  # zero out the rest of the free space using dd, then delete the written file.
  dd if=/dev/zero of=/EMPTY bs=4M status=progress || rm -f /EMPTY
  dd if=/dev/zero of=/data/EMPTY bs=4M status=progress || rm -f /data/EMPTY
  # run sync so Packer doesn't quit too early, before the large file is deleted.
  sync

  yum clean all
}

install_k3s
deploy_resources
cleanup
