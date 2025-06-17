#!/bin/bash
#
# This script configures the machine as an NFS client to mount a shared /home directory.
# It should be run on every compute node.

set -e # Exit immediately if a command exits with a non-zero status.

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

# --- Configuration ---
# Prompt for the NFS server hostname/IP
read -p "Enter the hostname or IP address of the NFS server (your Slurm controller): " NFS_SERVER

if [ -z "$NFS_SERVER" ]; then
    echo "Error: NFS server address cannot be empty." >&2
    exit 1
fi

echo "--- Starting NFS Client Setup for server: $NFS_SERVER ---"

# 1. Install NFS Client Packages
echo "[1/4] Installing nfs-common..."
apt-get update > /dev/null
apt-get install -y nfs-common

# 2. Prepare for Mounting
echo "[2/4] Preparing /home for network mount..."
# Check if /home is already a network mount
if mountpoint -q /home && ! grep -q "$NFS_SERVER:/home" /proc/mounts; then
    echo "Backing up local /home directory to /home.bak..."
    # Unmount just in case it's a separate local partition
    umount /home || true 
    mv /home /home.bak
    mkdir /home
    echo "Local /home directory backed up."
elif [ ! -d "/home" ]; then
    mkdir /home
fi

# 3. Configure fstab for automatic mounting
echo "[3/4] Configuring /etc/fstab for automatic mount..."
FSTAB_ENTRY="$NFS_SERVER:/home    /home    nfs    defaults    0    0"

# Create a backup of the original file
cp /etc/fstab /etc/fstab.bak.$(date +%F)

# Add the fstab entry, avoiding duplicates
if ! grep -q "$NFS_SERVER:/home" /etc/fstab; then
    echo -e "\n# Mount /home from the Slurm controller\n$FSTAB_ENTRY" >> /etc/fstab
else
    echo "fstab entry already exists. Skipping."
fi

# 4. Mount the Filesystem
echo "[4/4] Mounting all filesystems from fstab..."
mount -a

echo "--- NFS Client Setup Complete ---"
if mount | grep -q "$NFS_SERVER:/home"; then
    echo "Successfully mounted $NFS_SERVER:/home on /home."
    df -h /home
else
    echo "Error: Failed to mount $NFS_SERVER:/home. Please check your configuration and network."
    exit 1
fi
