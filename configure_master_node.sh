#!/bin/bash
#
# Configure this machine as the Slurm MASTER/CONTROLLER node for a multi-node cluster.
# Run this AFTER install.sh has completed successfully.
#
# This script will:
# 1. Detect hardware and regenerate slurm.conf for multi-node support
# 2. Set up NFS to share /home
# 3. Prepare files for compute nodes to copy
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use sudo.${NC}" >&2
    exit 1
fi

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Slurm Master Node Configuration${NC}"
echo -e "${GREEN}=========================================${NC}"

# Check if Slurm is installed
if ! command -v slurmctld &> /dev/null; then
    echo -e "${RED}Error: Slurm is not installed. Please run install.sh first.${NC}"
    exit 1
fi

MASTER_HOSTNAME=$(hostname)
MASTER_IP=$(hostname -I | awk '{print $1}')

echo -e "${YELLOW}Master node: $MASTER_HOSTNAME ($MASTER_IP)${NC}"

# Get hardware info
echo "Detecting hardware..."
HW_INFO=$(/usr/sbin/slurmd -C 2>/dev/null || echo "")
if [ -z "$HW_INFO" ]; then
    echo -e "${RED}Error: Cannot detect hardware. Is Slurm installed correctly?${NC}"
    exit 1
fi

CPUS=$(echo "$HW_INFO" | grep -o 'CPUs=[0-9]*' | cut -d'=' -f2)
REAL_MEMORY=$(echo "$HW_INFO" | grep -o 'RealMemory=[0-9]*' | cut -d'=' -f2)

echo "  CPUs: $CPUS"
echo "  Memory: $REAL_MEMORY MB"

# Check for GPUs
GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo 0)
if [ -z "$GPU_COUNT" ] || ! [[ "$GPU_COUNT" =~ ^[0-9]+$ ]]; then
    GPU_COUNT=0
fi

if [ "$GPU_COUNT" -gt 0 ]; then
    GPU_MODEL=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -n 1 | tr ' ' '_')
    echo "  GPUs: $GPU_COUNT x $GPU_MODEL"
    GRES_CONFIG="Gres=gpu:$GPU_MODEL:$GPU_COUNT"
    GRES_TYPES_CONFIG="GresTypes=gpu"
    PARTITION_NAME="gpu"
else
    echo "  GPUs: None detected"
    GRES_CONFIG=""
    GRES_TYPES_CONFIG=""
    PARTITION_NAME="compute"
fi

# Prompt for compute nodes
echo ""
echo -e "${YELLOW}Enter the hostnames of your compute nodes (space-separated).${NC}"
echo "Example: compute1 compute2"
echo "Leave empty if you want to add them later."
read -p "Compute nodes: " COMPUTE_NODES_INPUT

# Parse compute nodes
COMPUTE_NODES=($COMPUTE_NODES_INPUT)
ALL_NODES="$MASTER_HOSTNAME"
for node in "${COMPUTE_NODES[@]}"; do
    ALL_NODES="$ALL_NODES,$node"
done

# Prompt for network range for NFS
echo ""
echo -e "${YELLOW}Enter your network range for NFS sharing (e.g., 10.211.55.0/24):${NC}"
read -p "Network range [$MASTER_IP/24 detected]: " NETWORK_RANGE
if [ -z "$NETWORK_RANGE" ]; then
    # Auto-detect network range from IP
    NETWORK_BASE=$(echo $MASTER_IP | cut -d. -f1-3)
    NETWORK_RANGE="${NETWORK_BASE}.0/24"
fi
echo "Using network range: $NETWORK_RANGE"

echo ""
echo -e "${GREEN}Generating Slurm configuration...${NC}"

# Backup existing config
if [ -f /etc/slurm/slurm.conf ]; then
    cp /etc/slurm/slurm.conf /etc/slurm/slurm.conf.bak.$(date +%F-%H%M%S)
fi

# Generate slurm.conf
cat << EOF > /etc/slurm/slurm.conf
# slurm.conf - Multi-node cluster configuration
# Generated on $(date) for master: $MASTER_HOSTNAME

ClusterName=cluster
SlurmctldHost=$MASTER_HOSTNAME
MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=2
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurm/slurmd
SlurmUser=slurm
StateSaveLocation=/var/spool/slurm
SwitchType=switch/none
TaskPlugin=task/affinity

# TIMERS
InactiveLimit=0
KillWait=30
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=300
Waittime=0

# SCHEDULING
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# LOGGING
SlurmctldDebug=info
SlurmdDebug=info
SlurmctldLogFile=/var/log/slurmctld.log
SlurmdLogFile=/var/log/slurmd.log

# ACCOUNTING
AccountingStorageType=accounting_storage/none
JobAcctGatherType=jobacct_gather/none

# GRES CONFIG
$GRES_TYPES_CONFIG

# ===========================================
# COMPUTE NODES - Add new nodes here
# ===========================================
# Master node (also acts as compute)
NodeName=$MASTER_HOSTNAME CPUs=$CPUS RealMemory=$REAL_MEMORY $GRES_CONFIG State=UNKNOWN

# Compute nodes - UPDATE THESE with actual hardware specs after running install.sh on each
# Run 'slurmd -C' on each compute node to get CPUs and RealMemory values
EOF

# Add compute node placeholders
for node in "${COMPUTE_NODES[@]}"; do
    echo "NodeName=$node CPUs=REPLACE_CPUS RealMemory=REPLACE_MEMORY State=UNKNOWN" >> /etc/slurm/slurm.conf
done

# Add partition
echo "" >> /etc/slurm/slurm.conf
echo "# PARTITION" >> /etc/slurm/slurm.conf
echo "PartitionName=$PARTITION_NAME Nodes=$ALL_NODES Default=YES MaxTime=INFINITE State=UP" >> /etc/slurm/slurm.conf

# Generate gres.conf if GPUs present
if [ "$GPU_COUNT" -gt 0 ]; then
    echo "Creating gres.conf..."
    cat << EOF > /etc/slurm/gres.conf
# gres.conf - GPU configuration
# Master node GPUs
EOF
    for (( i=0; i<$GPU_COUNT; i++ )); do
        echo "NodeName=$MASTER_HOSTNAME Name=gpu Type=$GPU_MODEL File=/dev/nvidia$i" >> /etc/slurm/gres.conf
    done
    echo "" >> /etc/slurm/gres.conf
    echo "# Add compute node GPUs below (after installing on each node)" >> /etc/slurm/gres.conf
fi

# Ensure cgroup.conf exists
if [ ! -f /etc/slurm/cgroup.conf ]; then
    cat << EOF > /etc/slurm/cgroup.conf
CgroupPlugin=cgroup/v2
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
EOF
fi

# Fix permissions
chown -R slurm:slurm /etc/slurm
chmod 644 /etc/slurm/slurm.conf
chmod 644 /etc/slurm/cgroup.conf
[ -f /etc/slurm/gres.conf ] && chmod 644 /etc/slurm/gres.conf

echo -e "${GREEN}Setting up NFS server...${NC}"

# Install NFS server
apt-get update > /dev/null
apt-get install -y nfs-kernel-server

# Configure exports
if ! grep -q "^/home " /etc/exports 2>/dev/null; then
    echo "/home    $NETWORK_RANGE(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    echo "Added /home to NFS exports"
else
    echo "/home already exported"
fi

# Apply and start NFS
exportfs -a
systemctl restart nfs-kernel-server
systemctl enable nfs-kernel-server

# Firewall rules if ufw is active
if command -v ufw &> /dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow from $NETWORK_RANGE to any port nfs
    ufw allow from $NETWORK_RANGE to any port 6817  # slurmctld
    ufw allow from $NETWORK_RANGE to any port 6818  # slurmd
    echo "Firewall rules added"
fi

# Restart Slurm services
echo -e "${GREEN}Restarting Slurm services...${NC}"
systemctl restart munge
sleep 2
systemctl restart slurmctld
sleep 2
systemctl restart slurmd

# Create a package for compute nodes
echo -e "${GREEN}Creating config package for compute nodes...${NC}"
PACKAGE_DIR="/tmp/slurm_compute_package"
rm -rf $PACKAGE_DIR
mkdir -p $PACKAGE_DIR

cp /etc/slurm/slurm.conf $PACKAGE_DIR/
cp /etc/slurm/cgroup.conf $PACKAGE_DIR/
[ -f /etc/slurm/gres.conf ] && cp /etc/slurm/gres.conf $PACKAGE_DIR/
cp /etc/munge/munge.key $PACKAGE_DIR/
chmod 644 $PACKAGE_DIR/*

# Create info file
cat << EOF > $PACKAGE_DIR/master_info.txt
MASTER_HOSTNAME=$MASTER_HOSTNAME
MASTER_IP=$MASTER_IP
NETWORK_RANGE=$NETWORK_RANGE
EOF

tar -czf /home/slurm_cluster_config.tar.gz -C /tmp slurm_compute_package
chmod 644 /home/slurm_cluster_config.tar.gz
rm -rf $PACKAGE_DIR

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Master Node Configuration Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Config package created at: /home/slurm_cluster_config.tar.gz"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "1. Add compute node IPs to /etc/hosts on this machine"
echo "2. Copy these files to each compute node:"
echo "   - deploy_compute_node.sh"
echo "   - /home/slurm_cluster_config.tar.gz"
echo "3. Run deploy_compute_node.sh on each compute node"
echo "4. After all nodes are up, update /etc/slurm/slurm.conf with actual hardware specs"
echo "5. Run: sudo scontrol reconfigure"
echo ""
echo "Current cluster status:"
sinfo 2>/dev/null || echo "(slurmctld may still be starting)"
