# Bizon Slurm Cluster Manager

A comprehensive solution for automated Slurm cluster installation, configuration, and management on Ubuntu 24.04. Supports both **single-node** and **multi-node** clusters with full **NVIDIA GPU** scheduling and a modern **Web UI** for cluster management.

## Features

### Core Features
- **Automated Installation**: Installs Slurm 24.05.2 and dependencies from source
- **Multi-Architecture**: Supports both **x86_64** and **ARM64** systems
- **Hardware-Aware**: Auto-detects CPUs, memory, and NVIDIA GPUs
- **GPU Scheduling**: Full GRES support for GPU workloads with model-specific configuration
- **Multi-Node Support**: Deploy and manage clusters with multiple compute nodes
- **NFS Integration**: Automatic shared `/home` directory setup across nodes

### Web UI Features
- **Modern Dashboard**: Real-time cluster stats, node status, job queue
- **Node Management**: View detailed node info, drain/resume nodes
- **Job Management**: Submit, monitor, and cancel jobs from browser
- **Worker Deployment**: Add new compute nodes via SSH directly from Web UI
- **Interactive Terminal**: Full xterm.js terminal with WebSocket - run `htop`, `vim`, etc.
- **Fullscreen Mode**: Expand terminal to full screen (ESC to exit)
- **GPU Monitoring**: View GPU allocation and status per node
- **Storage Overview**: NFS mounts and disk usage display

## Prerequisites

1. **Operating System**: Ubuntu 24.04 LTS
2. **NVIDIA Drivers**: Must be installed and functional (`nvidia-smi` should work)
3. **Internet Connection**: Required to download Slurm source and dependencies
4. **Root Privileges**: Scripts require `sudo` access
5. **SSH Access** (for multi-node): Passwordless or password-based SSH between nodes

## Scripts

| Script | Description |
|--------|-------------|
| `install.sh` | Main installation for x86_64 systems |
| `install_arm64.sh` | Installation for ARM64 systems |
| `configure_master_node.sh` | Configure master for multi-node (x86_64) |
| `configure_master_node_arm64.sh` | Configure master for multi-node (ARM64) |
| `deploy_compute_node.sh` | Deploy worker node (x86_64) |
| `deploy_compute_node_arm64.sh` | Deploy worker node (ARM64) |
| `setup_nfs_server.sh` | Set up NFS server on master |
| `setup_nfs_client.sh` | Set up NFS client on workers |
| `run_gpu_burn_test.sbatch` | GPU verification test script |

---

## Quick Start: Single-Node Installation

```bash
git clone https://github.com/Gimel12/slurm_installation_24.04.git
cd slurm_installation_24.04

# For x86_64
sudo ./install.sh

# For ARM64
sudo ./install_arm64.sh
```

---

## Quick Start: Multi-Node Cluster

### Step 1: Install on Master Node

```bash
git clone https://github.com/Gimel12/slurm_installation_24.04.git
cd slurm_installation_24.04

# Install Slurm
sudo ./install.sh          # x86_64
# OR
sudo ./install_arm64.sh    # ARM64

# Configure for multi-node
sudo ./configure_master_node.sh          # x86_64
# OR
sudo ./configure_master_node_arm64.sh    # ARM64
```

### Step 2: Launch Web UI

```bash
cd slurm_web_ui
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 app.py
```

Access at: **http://<master-ip>:5000**

### Step 3: Add Workers via Web UI

1. Navigate to **Deploy** in the Web UI
2. Enter worker hostname/IP, SSH username, and password
3. Click **Deploy Worker**
4. The system will automatically install Slurm, configure GPUs, and join the cluster

## Verification

After the installation is complete, follow these steps to verify that Slurm is running correctly.

1.  **Check Service Status**:

    Ensure the `slurmctld`, `slurmd`, and `munge` services are active and running without errors.
    ```bash
    sudo systemctl status slurmctld slurmd munge
    ```

2.  **Check Node and GPU Status**:

    Use `sinfo` to check the status of the node and see the configured GPU resources. The node should be in an `idle` state.
    ```bash
    sinfo -o '%P %.10T %.15N %.12C %.10m %G'
    ```
    The output should look similar to this, showing your specific hardware:
    ```
    PARTITION      STATE        NODELIST CPUS(A/I/O/T)     MEMORY GRES
    gpu*           idle         my-node  0/20/0/20         95819  gpu:NVIDIA_GeForce_RTX_5090:1
    ```

3.  **Run the GPU Burn Test**:

    Submit the provided test script to Slurm to perform a live test of the GPU allocation. This is the best way to confirm the entire system is working.

    **Note**: The test script assumes the `gpu-burn` utility is located at `/home/bizon/Downloads/gpu-burn`. If your path is different, please edit the `run_gpu_burn_test.sbatch` file first.

    ```bash
    sbatch run_gpu_burn_test.sbatch
    ```

    After submitting, you can monitor the queue with `squeue`. Once the job is complete, check the output file (`gpu-burn-[job_id].out`) for the results. A successful test will show the GPU working at 100% utilization without errors.

---

## Web UI

The Bizon Slurm Manager includes a comprehensive web interface built with Flask, Tailwind CSS, and xterm.js.

### Features

| Page | Description |
|------|-------------|
| **Dashboard** | Cluster overview, stats, recent jobs, quick actions |
| **Nodes** | Node list with CPU/memory/GPU usage, drain/resume controls |
| **Jobs** | Job queue, submit new jobs, cancel running jobs |
| **Deploy** | Add new worker nodes via SSH |
| **Storage** | View NFS mounts and disk usage |
| **Settings** | Edit `slurm.conf`, view cluster configuration |
| **Node Detail** | Per-node details with **interactive terminal** |

### Interactive Terminal

The Web UI includes a full **xterm.js terminal** with WebSocket support:
- Run any command including interactive ones (`htop`, `vim`, `top`)
- Full color and cursor support
- Command history with arrow keys
- **Fullscreen mode** - click green dot or expand icon (ESC to exit)
- Works on both local master and remote worker nodes via SSH

### Running the Web UI

```bash
cd slurm_web_ui
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python3 app.py
```

Access at: **http://localhost:5000**

### Running as a Service (Optional)

To run the Web UI as a systemd service:

```bash
sudo tee /etc/systemd/system/slurm-webui.service << EOF
[Unit]
Description=Slurm Web UI
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)/slurm_web_ui
ExecStart=$(pwd)/slurm_web_ui/venv/bin/python3 app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now slurm-webui
```

---

## GPU Verification

Test GPU allocation with the included test script:

```bash
sbatch run_gpu_burn_test.sbatch
```

Check results:
```bash
squeue                           # View job status
cat gpu-burn-<job_id>.out        # View output
```

---

## Documentation

- `multi-node-guide.md` - Detailed multi-node setup guide
- `nfs-setup-guide.md` - NFS configuration for shared storage
- `MULTINODE_QUICKSTART.md` - Quick reference for multi-node deployment

---

## License

Copyright © 2026 Bizon. All rights reserved.

