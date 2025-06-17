#!/bin/bash
#
# This script configures the machine as an NFS server to share the /home directory.
# It should be run once on the Slurm controller node.

set -e # Exit immediately if a command exits with a non-zero status.

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

# --- Configuration ---
# Prompt for the network range
read -p "Enter the network range to grant NFS access to (e.g., 192.168.1.0/24): " NETWORK_RANGE

if [ -z "$NETWORK_RANGE" ]; then
    echo "Error: Network range cannot be empty." >&2
    exit 1
fi

echo "--- Starting NFS Server Setup ---"

# 1. Install NFS Server Packages
echo "[1/5] Installing nfs-kernel-server..."
apt-get update > /dev/null
apt-get install -y nfs-kernel-server

# 2. Configure the Shared Directory
echo "[2/5] Configuring /etc/exports to share /home with $NETWORK_RANGE..."

# Create a backup of the original file
cp /etc/exports /etc/exports.bak.$(date +%F)

# Add the export rule, avoiding duplicates
if ! grep -q "^/home " /etc/exports; then
    echo "/home    $NETWORK_RANGE(rw,sync,no_subtree_check)" >> /etc/exports
else
    echo "/home directory already exported. Skipping."
fi

# 3. Apply the Configuration
echo "[3/5] Applying NFS export configuration..."
exportfs -a

# 4. Start and Enable the NFS Server
echo "[4/5] Restarting and enabling nfs-kernel-server service..."
systemctl restart nfs-kernel-server
systemctl enable nfs-kernel-server

# 5. Adjust Firewall Rules (if ufw is active)
echo "[5/5] Adjusting firewall rules..."
if command -v ufw &> /dev/null && ufw status | grep -q 'Status: active'; then
    echo "UFW is active. Allowing NFS traffic from $NETWORK_RANGE..."
    ufw allow from $NETWORK_RANGE to any port nfs
else
    echo "UFW not active or not installed. Skipping firewall rule."
fi

echo "--- NFS Server Setup Complete ---"
echo "The /home directory is now shared with clients on the $NETWORK_RANGE network."
