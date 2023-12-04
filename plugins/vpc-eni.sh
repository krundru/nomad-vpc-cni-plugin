#!/usr/bin/env bash

# CNI Plug to create secondary ENI/NIC to move it to Container Namespace to provide reachable address.

export IMD_URL="http://169.254.169.254/latest/meta-data"
export CNI_LOG_FILE="/var/log/nomad/cni.log"

# Function to log messages to a file
cni_log() {
  local log_file="/var/log/nomad/cni.log"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local message="$timestamp - $*"
  command printf %s\\n "$message" >> "$CNI_LOG_FILE"
}

# Function to read the CNI configuration from stdin
cni_config() {
  local confg=$(cat)
  echo $confg
}

# Prepare CNI result to stdout
cni_result() {
  local config=$1
  local result=$(echo "$config" | jq -r '.prevResult')
  echo $result
}

# Function to export AWS related variables
cni_export_vars() {
  export RUN_ID=$(echo $CNI_CONTAINERID | cut -c1-8)
  export TMP_DIR=/tmp/cni-${RUN_ID}
  export INSTANCE_ID=$(curl -s $IMD_URL/instance-id)
  export AVAILABILITY_ZONE=$(curl -s $IMD_URL/placement/availability-zone)
  export REGION=$(echo $AVAILABILITY_ZONE | sed 's/[a-z]$//')
  export AWS_DEFAULT_REGION=$REGION
  export PRIMARY_MAC_ADDRESS=$(curl -s $IMD_URL/mac)
  export SUBNET_ID=$(curl -s $IMD_URL/network/interfaces/macs/$PRIMARY_MAC_ADDRESS/subnet-id)
}

# Function to read the ENI ID from the eni.json file
cni_get_eni_id() {
  local eni_id=$(cat $TMP_DIR/eni.json | jq -r '.NetworkInterface.NetworkInterfaceId')
  echo $eni_id
}

# Function to create a new ENI and attach it to the instance
cni_create_eni() {
  # Use AWS CLI to create a new ENI and attach it to the instance
  aws ec2 create-network-interface \
    --subnet-id $SUBNET_ID \
    --groups $SECURITY_GROUP_ID \
    --tag-specifications 'ResourceType=network-interface,Tags=[{Key=Name,Value=NomadSecENI}]' \
    --region $REGION &> $TMP_DIR/eni.json
  if [ $? -ne 0 ]; then
    cni_log "Failed to create a new ENI."
    exit 1
  fi

  ENI_ID=$(cni_get_eni_id $TMP_DIR)
  cni_log "New ENI ID: $ENI_ID"

  # TODO Retry if the DataIndex is already in use
  local MAC_COUNT=$(curl -s -w "\n" $IMD_URL/network/interfaces/macs/ | wc -l)
  export DataIndex=$MAC_COUNT
  # Attach the new ENI to the current instance
  aws ec2 attach-network-interface \
    --network-interface-id $ENI_ID \
    --instance-id $INSTANCE_ID \
    --device-index $DataIndex \
    --region $REGION &> $TMP_DIR/attach.json

  if [ $? -ne 0 ]; then
    cni_log "Failed to attach ENI ($ENI_ID) to the instance ($INSTANCE_ID)."
    exit 1
  fi

  cni_log "New ENI ($ENI_ID) created and attached to the instance ($INSTANCE_ID)."

  export LinkDevice="eth$DataIndex"
  # TODO Retry if the ENI is not attached
  sleep 10
}

# Function detach the ENI from the instance and delete it
cni_delete_eni() {
  # read attachment id from attach.json
  local AttachmentId=$(cat $TMP_DIR/attach.json | jq -r '.AttachmentId')
  cni_log "ENI Attachment ID to be detached: $AttachmentId"

  aws ec2 detach-network-interface \
    --attachment-id $AttachmentId \
    --region $REGION > $TMP_DIR/detach.json 2>&1
  cni_log "Detach ENI command output: $?"
  if [ $? -ne 0 ]; then
    cni_log "Failed to detach ENI using attachment id ($AttachmentId)."
    return 0
  fi

    # if eni.json exists, then delete the ENI
  if [ ! -f $TMP_DIR/eni.json ]; then
    cni_log "ENI ($ENI_ID) does not exist."
    return 0
  fi

  ENI_ID=$(cni_get_eni_id)
  cni_log "ENI ID to be deleted: $ENI_ID"
  # TODO Retry if the ENI is still in use
  sleep 5
  aws ec2 delete-network-interface \
    --network-interface-id $ENI_ID \
    --region $REGION &> $TMP_DIR/delete.json
  if [ $? -ne 0 ]; then
    cni_log "Failed to delete ENI ($ENI_ID)."
    return 0
  fi

  cni_log "ENI ($ENI_ID) deleted."
}

# Function to get the IP address of the ENI
cni_get_eni_ip() {
  local dev=$LinkDevice
  inetaddr=$(ip addr show dev "$dev" | grep -oP 'inet \K[\d.]+/\d+')
  echo $inetaddr
}

# Function to get the gateway of the ENI
cni_get_eni_gateway() {
  gateway=$(ip route | grep "default" | head -1 | grep -oP 'default via \K[\d.]+')
  echo $gateway
}

# Function to get the broadcast address of the ENI
cni_get_eni_broadcast() {
  local dev=$LinkDevice
  broadcast=$(ip addr show dev "$dev" | grep -oP 'brd \K[\d.]+')
  echo $broadcast
}

cni_symlink_add_netns() {
  mkdir -p /var/run/netns/
  ln -sfT $CNI_NETNS /var/run/netns/$CNI_CONTAINERID
}

cni_symlink_del_netns() {
  rm -f /var/run/netns/$CNI_CONTAINERID
}

# Function to move the secondary ENI NIC to the container's network namespace
cni_move_eni_nic_to_netns() {
  local dev="$LinkDevice"
  ip link set "$dev" netns $CNI_CONTAINERID
  ip netns exec $CNI_CONTAINERID ip link set "$dev" name eth1
  ip netns exec $CNI_CONTAINERID ip link set lo up
  ip netns exec $CNI_CONTAINERID ip link set eth1 up
  cni_log "dev $dev moved to netns $CNI_CONTAINERID"
}

# Function to add the IP address of the ENI to the container's eth1 NIC and set the broadcast address
cni_add_addr_to_netns_nic() {
  local inetaddr="$1"
  local broadcast="$2"
  ip netns exec $CNI_CONTAINERID ip addr add $inetaddr broadcast $broadcast dev eth1
  cni_log "ip address $inetaddr broadcast $broadcast added to eth1 in $CNI_CONTAINERID netns"
}

cni_add_default_route_netns() {
  # remove default route if exists
  ip netns exec $CNI_CONTAINERID ip route del default 2>/dev/null || true
  local gateway="$1"
  ip netns exec $CNI_CONTAINERID ip route add default via $gateway dev eth1
  cni_log "default route added to eth1 in $CNI_CONTAINERID netns"
}

cni_exec_add_command() {
  (
    set -e
    cni_create_eni
    local dev="$LinkDevice" 
    # get ip address of eth1 from ifconfig
    local inetaddr=$(ip addr show dev "$dev" | grep -oP 'inet \K[\d.]+/\d+')
    local gateway=$(ip route | grep "default" | head -1 | grep -oP 'default via \K[\d.]+')
    local broadcast=$(ip addr show dev "$dev" | grep -oP 'brd \K[\d.]+')
    cni_log "inetaddr: $inetaddr, gateway: $gateway, broadcast: $broadcast, dev: $dev"

    cni_symlink_add_netns
    cni_move_eni_nic_to_netns
    cni_add_addr_to_netns_nic $inetaddr $broadcast
    cni_add_default_route_netns $gateway
  )
}

cni_exec_del_command() {
  cni_symlink_del_netns
  cni_delete_eni
  cni_log "Command is not ADD, exiting";
}

# ---------------------------------------------------------------------------
# CNI Plugin starts here ...
# ---------------------------------------------------------------------------
cni_export_vars
# Read the CNI_CONTAINERID and CNI_NETNS environment variables
cni_log "CNI plugin is invoked with arguments:..."
cni_log "cni command = $CNI_COMMAND"
cni_log "cni container id = $CNI_CONTAINERID"
cni_log "cni netns path = $CNI_NETNS"
cni_log "cni ifname = $CNI_IFNAME"
cni_log "path = $CNI_PATH"
cni_log "args = $CNI_ARGS"
cni_log "cni temp dir: $TMP_DIR"
cni_log "AWS (Instance ID: $INSTANCE_ID, Region: $REGION, Subnet ID: $SUBNET_ID)"

mkdir -p $TMP_DIR
# Read and print the configuration from stdin
config=$(cni_config)
cni_log "Received CNI Config: $config"
result=$(cni_result $config)
cni_log "Result of the CNI: $result"

# switch on CNI_COMMAND
case "$CNI_COMMAND" in
  ADD)
    cni_exec_add_command
    if [ $? -ne 0 ]; then
      cni_log "Failed to execute ADD command."
      echo "{\"cniVersion\": \"0.3.1\", \"code\": 1, \"msg\": \"Failed to execute ADD command.\"}"
      exit 1
    fi
    echo $result
    ;;
  DEL)
    cni_exec_del_command
    echo $result
    ;;
  *)
    cni_log "Command is not ADD or DEL, exiting"
    echo $result
    exit 0
    ;;
esac

exit 0
