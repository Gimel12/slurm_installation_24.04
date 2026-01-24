# Multi-Node Slurm Cluster - Quick Start Guide

This guide walks you through deploying a 3-VM Slurm cluster.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        MASTER NODE                          │
│  VM1: ubuntu-linux-2404 (10.211.55.24)                     │
│  - slurmctld (controller daemon)                           │
│  - slurmd (also acts as compute)                           │
│  - NFS server (shares /home)                               │
└─────────────────────────────────────────────────────────────┘
                           │
            ┌──────────────┴──────────────┐
            ▼                             ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│     COMPUTE NODE 1      │   │     COMPUTE NODE 2      │
│  VM2: compute1          │   │  VM3: compute2          │
│  - slurmd only          │   │  - slurmd only          │
│  - NFS client           │   │  - NFS client           │
└─────────────────────────┘   └─────────────────────────┘
```

## Prerequisites

- 3 VMs running Ubuntu 24.04
- All VMs on the same network (can ping each other)
- Root/sudo access on all VMs

---

## Step 1: Prepare Networking (ALL VMs)

On **each VM**, add entries to `/etc/hosts` so they can resolve each other:

```bash
sudo nano /etc/hosts
```

Add lines like:
```
10.211.55.24    ubuntu-linux-2404    master
10.211.55.25    compute1
10.211.55.26    compute2
```

**Replace IPs with your actual VM IPs.**

---

## Step 2: Setup Master Node (VM1)

Your master already has `install.sh` run. Now configure it for multi-node:

```bash
# If install.sh didn't complete, run it first:
sudo ./install.sh --without-interaction

# Then configure for multi-node:
sudo ./configure_master_node.sh
```

This will:
- Regenerate `slurm.conf` for multi-node
- Setup NFS server to share `/home`
- Create `/home/slurm_cluster_config.tar.gz` for compute nodes

---

## Step 3: Deploy Compute Nodes (VM2 & VM3)

### 3a. Copy files to each compute node

From the master node:
```bash
# Copy to compute1
scp deploy_compute_node.sh /home/slurm_cluster_config.tar.gz user@compute1:/tmp/

# Copy to compute2
scp deploy_compute_node.sh /home/slurm_cluster_config.tar.gz user@compute2:/tmp/
```

### 3b. Run deployment on each compute node

SSH to each compute node and run:
```bash
cd /tmp
sudo bash deploy_compute_node.sh
```

The script will output the `NodeName` line you need to add to the master's config.

---

## Step 4: Update Master Configuration

After deploying each compute node, you'll get hardware specs. Update the master's `/etc/slurm/slurm.conf`:

```bash
sudo nano /etc/slurm/slurm.conf
```

Update the node definitions with actual values:
```
NodeName=ubuntu-linux-2404 CPUs=4 RealMemory=7900 State=UNKNOWN
NodeName=compute1 CPUs=4 RealMemory=7900 State=UNKNOWN
NodeName=compute2 CPUs=4 RealMemory=7900 State=UNKNOWN

PartitionName=compute Nodes=ubuntu-linux-2404,compute1,compute2 Default=YES MaxTime=INFINITE State=UP
```

Then apply changes:
```bash
sudo scontrol reconfigure
```

---

## Step 5: Bring Nodes Online

Check cluster status:
```bash
sinfo
```

If nodes show as `down` or `drain`, bring them online:
```bash
sudo scontrol update NodeName=compute1 State=IDLE
sudo scontrol update NodeName=compute2 State=IDLE
```

---

## Step 6: Test the Cluster

```bash
# Check all nodes
sinfo

# Run a test job on all nodes
srun -N3 hostname

# Submit a batch job
sbatch --wrap="hostname && sleep 10" -N 1
```

---

## Troubleshooting

### Node stuck in DOWN state
```bash
# Check why node is down
scontrol show node compute1

# Check slurmd logs on the compute node
sudo journalctl -u slurmd -f

# Force node online
sudo scontrol update NodeName=compute1 State=RESUME
```

### Munge authentication errors
```bash
# Verify munge key is identical on all nodes
md5sum /etc/munge/munge.key  # Run on all nodes, should match

# Test munge
munge -n | ssh compute1 unmunge
```

### NFS mount issues
```bash
# On compute node, check mount
df -h /home

# Manually mount
sudo mount master:/home /home
```

### Cannot resolve hostname
```bash
# Verify /etc/hosts is correct on all nodes
ping master
ping compute1
```

---

## File Reference

| File | Purpose |
|------|---------|
| `install.sh` | Initial Slurm installation (run on all nodes) |
| `configure_master_node.sh` | Configure master for multi-node + NFS |
| `deploy_compute_node.sh` | Deploy compute node and join cluster |
| `/etc/slurm/slurm.conf` | Main Slurm configuration |
| `/etc/slurm/gres.conf` | GPU configuration |
| `/etc/munge/munge.key` | Authentication key (must match on all nodes) |
