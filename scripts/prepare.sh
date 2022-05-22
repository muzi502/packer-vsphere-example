#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

kubectl get pods --no-headers -n kube-system | grep -E '0/2|0/1|Error|Unknown|CreateContainerError|CrashLoopBackOff' | awk '{print $1}' | xargs -t -I {} kubectl delete pod -n kube-system --grace-period=0 --force {} > /dev/null  2>&1 || true
kubectl get pods --no-headers -n default | grep -E '0/1|Error|Unknown|CreateContainerError|CrashLoopBackOff' | awk '{print $1}' | xargs -t -I {} kubectl delete pod -n default --grace-period=0 --force {} > /dev/null  2>&1 || true
while true; do
  if kubectl get pods --no-headers --all-namespaces | grep -Ev 'Running|Completed'; then
    echo "Waiting for service readiness"
    sleep 10
  else
    break
  fi
done

cat > ${HOME}/.goss-vars.yaml << EOF
ip_address: $(ip r get 1 | sed "s/ uid.*//g" | awk '{print $NF}' | head -n1)
cpu_core_number: $(grep -c ^processor /proc/cpuinfo)
memory_size: $(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
available_memory_size: $(grep '^MemAvailable:' /proc/meminfo | awk '{print $2}')
EOF
goss --vars ${HOME}/.goss-vars.yaml -g ${HOME}/.goss.yaml validate --retry-timeout=10s
