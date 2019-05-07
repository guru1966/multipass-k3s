#!/usr/bin/env bash

# Configure your settings
# Name for the cluster/configuration files
NAME=""
# Ubuntu image to use (xenial/bionic)
IMAGE="bionic"
# How many machines to create
SERVER_COUNT_MACHINE="1"
# How many machines to create
AGENT_COUNT_MACHINE="1"
# How many CPUs to allocate to each machine
SERVER_CPU_MACHINE="1"
AGENT_CPU_MACHINE="1"
# How much disk space to allocate to each machine
SERVER_DISK_MACHINE="3G"
AGENT_DISK_MACHINE="3G"
# How much memory to allocate to each machine
SERVER_MEMORY_MACHINE="512M"
AGENT_MEMORY_MACHINE="256M"
# Preconfigured secret to join the cluster (or autogenerated if empty)
CLUSTER_SECRET=""

## Nothing to change after this line
if [ -x "$(command -v multipass.exe)" > /dev/null 2>&1 ]; then
    # Windows
    MULTIPASSCMD="multipass.exe"
elif [ -x "$(command -v multipass)" > /dev/null 2>&1 ]; then
    # Linux/MacOS
    MULTIPASSCMD="multipass"
else
    echo "The multipass binary (multipass or multipass.exe) is not available or not in your \$PATH"
    exit 1
fi

if [ -z $CLUSTER_SECRET ]; then
    CLUSTER_SECRET=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No cluster secret given, generated secret: ${CLUSTER_SECRET}"
fi

# Check if name is given or create random string
if [ -z $NAME ]; then
    NAME=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No name given, generated name: ${NAME}"
fi

echo "Creating cluster ${NAME} with ${SERVER_COUNT_MACHINE} servers and ${AGENT_COUNT_MACHINE} agents"

# Prepare cloud-init
# Cloud init template
read -r -d '' SERVER_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | K3S_CLUSTER_SECRET=$CLUSTER_SECRET sh -'
EOM

echo "$SERVER_CLOUDINIT_TEMPLATE" > "${NAME}-cloud-init.yaml"
echo "Cloud-init is created at ${NAME}-cloud-init.yaml"

for i in $(eval echo "{1..$SERVER_COUNT_MACHINE}"); do
    echo "Running $MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init ${NAME}-cloud-init.yaml"                                                                                                                                           
    $MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init "${NAME}-cloud-init.yaml"
    if [ $? -ne 0 ]; then
        echo "There was an error launching the instance"
        exit 1
    fi
done

for i in $(eval echo "{1..$SERVER_COUNT_MACHINE}"); do
    echo "Checking for Node being Ready on k3s-server-${NAME}-${i}"
    $MULTIPASSCMD exec k3s-server-$NAME-$i -- /bin/bash -c 'while [[ $(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do sleep 2; done'
    echo "Node is Ready on k3s-server-${NAME}-${i}"
done

# Retrieve info to join agent to cluster
SERVER_IP=$($MULTIPASSCMD info k3s-server-$NAME-1 | grep IPv4 | awk '{ print $2 }')
URL="https://$(echo $SERVER_IP | sed -e 's/[[:space:]]//g'):6443"

# Cloud init template
read -r -d '' AGENT_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | K3S_CLUSTER_SECRET=$CLUSTER_SECRET K3S_URL=$URL sh -'
EOM

# Prepare agent cloud-init
echo "$AGENT_CLOUDINIT_TEMPLATE" > "${NAME}-agent-cloud-init.yaml"
echo "Cloud-init is created at ${NAME}-agent-cloud-init.yaml"

for i in $(eval echo "{1..$AGENT_COUNT_MACHINE}"); do
    echo "Running $MULTIPASSCMD launch --cpus $AGENT_CPU_MACHINE --disk $AGENT_DISK_MACHINE --mem $AGENT_MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init ${NAME}-agent-cloud-init.yaml"
    $MULTIPASSCMD launch --cpus $AGENT_CPU_MACHINE --disk $AGENT_DISK_MACHINE --mem $AGENT_MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init "${NAME}-agent-cloud-init.yaml"
    if [ $? -ne 0 ]; then
        echo "There was an error launching the instance"
        exit 1
    fi
    echo "Checking for Node k3s-agent-$NAME-$i being registered"
    $MULTIPASSCMD exec k3s-server-$NAME-1 -- bash -c "until k3s kubectl get nodes --no-headers | grep -c k3s-agent-$NAME-1 >/dev/null; do sleep 2; done" 
    echo "Checking for Node k3s-agent-$NAME-$i being Ready"
    $MULTIPASSCMD exec k3s-server-$NAME-1 -- bash -c "until k3s kubectl get nodes --no-headers | grep k3s-agent-$NAME-1 | grep -c -v NotReady >/dev/null; do sleep 2; done" 
    echo "Node k3s-agent-$NAME-$i is Ready on k3s-server-${NAME}-1"
done

$MULTIPASSCMD copy-files k3s-server-$NAME-1:/etc/rancher/k3s/k3s.yaml $NAME-kubeconfig-orig.yaml
sed "/^[[:space:]]*server:/ s_:.*_: \"https://$(echo $SERVER_IP | sed -e 's/[[:space:]]//g'):6443\"_" $NAME-kubeconfig-orig.yaml > $NAME-kubeconfig.yaml

echo "k3s setup finished"
$MULTIPASSCMD exec k3s-server-$NAME-1 -- k3s kubectl get nodes
echo "You can now use the following command to connect to your cluster"
echo "$MULTIPASSCMD exec k3s-server-${NAME}-1 -- k3s kubectl get nodes"
echo "Or use kubectl directly"
echo "kubectl --kubeconfig ${NAME}-kubeconfig.yaml get nodes"
