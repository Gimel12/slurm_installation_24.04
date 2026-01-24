#!/bin/bash
#
# Deploy this machine as a Slurm COMPUTE NODE (ARM64 version)
# Run this script on each compute node to join the cluster.
#
# Prerequisites:
# 1. Ubuntu 24.04 (ARM64/aarch64)
# 2. Network connectivity to master node
# 3. slurm_cluster_config.tar.gz from master node (place in same directory as this script)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SLURM_VERSION="24.05.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use sudo.${NC}" >&2
    exit 1
fi

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Slurm Compute Node Deployment (ARM64)${NC}"
echo -e "${GREEN}=========================================${NC}"

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo -e "${RED}This script is for ARM64 (aarch64) only. Detected: $ARCH${NC}"
    echo "Use deploy_compute_node.sh for x86_64 systems."
    exit 1
fi

COMPUTE_HOSTNAME=$(hostname)
COMPUTE_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}This node: $COMPUTE_HOSTNAME ($COMPUTE_IP)${NC}"

# Check for config package
CONFIG_PACKAGE="$SCRIPT_DIR/slurm_cluster_config.tar.gz"
if [ ! -f "$CONFIG_PACKAGE" ]; then
    CONFIG_PACKAGE="/tmp/slurm_cluster_config.tar.gz"
fi

if [ ! -f "$CONFIG_PACKAGE" ]; then
    echo -e "${RED}Error: slurm_cluster_config.tar.gz not found!${NC}"
    echo "Please copy it from the master node to this directory or /tmp/"
    exit 1
fi

# Extract config package
echo "Extracting cluster configuration..."
tar -xzf "$CONFIG_PACKAGE" -C /tmp/
CONFIG_DIR="/tmp/slurm_compute_package"

# Read master info
source $CONFIG_DIR/master_info.txt
echo "Master node: $MASTER_HOSTNAME ($MASTER_IP)"

# Verify connectivity to master
echo "Testing connectivity to master node..."
if ! ping -c 1 -W 3 $MASTER_IP &>/dev/null; then
    echo -e "${YELLOW}Warning: Cannot ping master node at $MASTER_IP${NC}"
    echo "Make sure networking is configured correctly."
    read -p "Continue anyway? [y/N]: " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check Ubuntu version
ubuntu_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
if [ "$ubuntu_version" != "24.04" ]; then
    echo -e "${YELLOW}Warning: This script is designed for Ubuntu 24.04. Detected: $ubuntu_version${NC}"
    read -p "Continue anyway? [y/N]: " CONTINUE
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create required users with consistent UIDs
echo -e "${GREEN}[1/8] Creating required users...${NC}"
MUNGEUSER=966
SLURMUSER=967

if ! getent group munge &>/dev/null; then
    groupadd -g $MUNGEUSER munge
fi
if ! id munge &>/dev/null; then
    useradd -m -c "MUNGE" -d /var/lib/munge -u $MUNGEUSER -g munge -s /sbin/nologin munge
fi

if ! getent group slurm &>/dev/null; then
    groupadd -g $SLURMUSER slurm
fi
if ! id slurm &>/dev/null; then
    useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURMUSER -g slurm -s /bin/bash slurm
fi

# Install dependencies
echo -e "${GREEN}[2/8] Installing dependencies...${NC}"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bzip2 \
    python3 \
    gcc \
    openssl \
    numactl \
    hwloc \
    lua5.3 \
    make \
    ruby \
    ruby-dev \
    libmunge-dev \
    libpam0g-dev \
    libdbus-1-dev \
    munge \
    libmunge2 \
    nfs-common \
    wget

# Check for NVIDIA GPU and install support if present
if command -v nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU detected, installing libnvidia-ml-dev..."
    apt-get install -y libnvidia-ml-dev || true
fi

# Setup munge
echo -e "${GREEN}[3/8] Setting up Munge authentication...${NC}"
cp $CONFIG_DIR/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
systemctl enable munge
systemctl restart munge

# Test munge
sleep 2
if munge -n | unmunge &>/dev/null; then
    echo "Munge is working locally"
else
    echo -e "${RED}Warning: Munge self-test failed${NC}"
fi

# Build Slurm
echo -e "${GREEN}[4/8] Building Slurm $SLURM_VERSION for ARM64...${NC}"
BUILD_DIR=$(mktemp -d)
cd $BUILD_DIR

wget --no-check-certificate https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to download Slurm. Exiting.${NC}"
    exit 1
fi

tar jxf slurm-${SLURM_VERSION}.tar.bz2
cd slurm-${SLURM_VERSION}

# ARM64 uses aarch64-linux-gnu for library paths
./configure --prefix=/usr \
            --sysconfdir=/etc/slurm \
            --enable-pam \
            --with-pam_dir=/lib/aarch64-linux-gnu/security/ \
            --without-shared-libslurm

make -j$(nproc)
make contrib
make install

cd /
rm -rf $BUILD_DIR

# Install Slurm configuration from master
echo -e "${GREEN}[5/8] Installing Slurm configuration...${NC}"
mkdir -p /etc/slurm
cp $CONFIG_DIR/slurm.conf /etc/slurm/
cp $CONFIG_DIR/cgroup.conf /etc/slurm/
[ -f $CONFIG_DIR/gres.conf ] && cp $CONFIG_DIR/gres.conf /etc/slurm/

chown -R slurm:slurm /etc/slurm
chmod 644 /etc/slurm/*.conf

# Create required directories
echo -e "${GREEN}[6/8] Creating required directories...${NC}"
mkdir -p /var/spool/slurm/slurmd
mkdir -p /var/log
touch /var/log/slurmd.log
chown -R slurm:slurm /var/spool/slurm
chown slurm:slurm /var/log/slurmd.log

# Setup systemd service for slurmd (compute nodes only run slurmd, NOT slurmctld)
echo -e "${GREEN}[7/8] Setting up systemd service...${NC}"
cat << 'EOF' > /etc/systemd/system/slurmd.service
[Unit]
Description=Slurm node daemon
After=network.target munge.service remote-fs.target
Wants=network-online.target

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmd
ExecStart=/usr/sbin/slurmd -d /usr/sbin/slurmstepd $SLURMD_OPTIONS
ExecReload=/bin/kill -HUP $MAINPID
PIDFile=/var/run/slurmd.pid
KillMode=process
LimitNOFILE=51200
LimitMEMLOCK=infinity
LimitSTACK=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Setup NFS client to mount /home from master
echo -e "${GREEN}[8/8] Setting up NFS client...${NC}"

# Check if /home is already an NFS mount
if mount | grep -q "$MASTER_IP:/home\|$MASTER_HOSTNAME:/home"; then
    echo "/home already mounted from master"
else
    # Backup local home if it exists and isn't empty
    if [ -d /home ] && [ "$(ls -A /home 2>/dev/null)" ]; then
        echo "Backing up local /home to /home.local.bak"
        mv /home /home.local.bak
        mkdir /home
    fi
    
    # Add fstab entry
    if ! grep -q "$MASTER_HOSTNAME:/home\|$MASTER_IP:/home" /etc/fstab; then
        echo "" >> /etc/fstab
        echo "# NFS mount from Slurm master" >> /etc/fstab
        echo "$MASTER_IP:/home    /home    nfs    defaults,_netdev    0    0" >> /etc/fstab
    fi
    
    # Mount
    mount -a || echo -e "${YELLOW}Warning: Could not mount NFS. Will retry after network is up.${NC}"
fi

# Get this node's hardware info for updating master config
echo ""
echo -e "${GREEN}Detecting hardware for slurm.conf update...${NC}"
HW_INFO=$(/usr/sbin/slurmd -C)
echo "$HW_INFO"

NODE_CPUS=$(echo "$HW_INFO" | grep -o 'CPUs=[0-9]*' | cut -d'=' -f2)
NODE_MEMORY=$(echo "$HW_INFO" | grep -o 'RealMemory=[0-9]*' | cut -d'=' -f2)

# Check for GPUs
GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null | head -1 || echo 0)
if [ -z "$GPU_COUNT" ] || ! [[ "$GPU_COUNT" =~ ^[0-9]+$ ]]; then
    GPU_COUNT=0
fi
if [ "$GPU_COUNT" -gt 0 ]; then
    GPU_MODEL=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -n 1 | tr ' ' '_')
    GRES_LINE="Gres=gpu:$GPU_MODEL:$GPU_COUNT"
else
    GRES_LINE=""
fi

# Start slurmd
echo -e "${GREEN}Starting slurmd service...${NC}"
systemctl enable slurmd
systemctl start slurmd

sleep 3

# Check status
if systemctl is-active --quiet slurmd; then
    echo -e "${GREEN}slurmd is running!${NC}"
else
    echo -e "${YELLOW}slurmd may not be running. Checking logs...${NC}"
    journalctl -u slurmd -n 10 --no-pager
fi

# Cleanup
rm -rf $CONFIG_DIR

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Compute Node Deployment Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Update the master node's /etc/slurm/slurm.conf${NC}"
echo ""
echo "Add/update this line on the MASTER node:"
echo -e "${GREEN}NodeName=$COMPUTE_HOSTNAME CPUs=$NODE_CPUS RealMemory=$NODE_MEMORY $GRES_LINE State=UNKNOWN${NC}"
echo ""
if [ "$GPU_COUNT" -gt 0 ]; then
    echo "Also add to /etc/slurm/gres.conf on the MASTER:"
    for (( i=0; i<$GPU_COUNT; i++ )); do
        echo -e "${GREEN}NodeName=$COMPUTE_HOSTNAME Name=gpu Type=$GPU_MODEL File=/dev/nvidia$i${NC}"
    done
    echo ""
fi
echo "Then on the MASTER, run:"
echo "  sudo scontrol reconfigure"
echo ""
echo "To bring this node online:"
echo "  sudo scontrol update NodeName=$COMPUTE_HOSTNAME State=IDLE"
