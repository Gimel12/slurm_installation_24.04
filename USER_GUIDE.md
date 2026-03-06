# Bizon Slurm Cluster - User Guide

## Quick Start

**Access the Web UI:** Open your browser and go to:
```
http://172.30.1.205:5000
```

You can access this from any computer on the same network.

---

## Cluster Overview

Your cluster has **3 compute nodes** with a total of **18 GPUs**:

| Node Name | GPUs | Type |
|-----------|------|------|
| master-gpu-7xrtx4090 | 7 | NVIDIA RTX 4090 |
| worker1-gpu-4xH200 | 4 | NVIDIA H200 NVL |
| worker2-gpu-7xrtx4090 | 7 | NVIDIA RTX 4090 |

---

## Web UI Pages

### 1. Dashboard
The main page shows:
- **Total Nodes** - How many machines are in the cluster
- **Running Jobs** - Jobs currently executing
- **Total CPUs/GPUs** - Available compute resources
- **Cluster Status** - Green = Online, Red = Issues
- **Node Status** - Quick view of each node's state (idle/allocated/down)

### 2. Nodes
Detailed view of each compute node:
- CPU and memory usage
- GPU count
- Current state
- Click a node name to see more details and access the terminal

### 3. Jobs
Manage your jobs:
- **Job Queue** - See all running and pending jobs
- **Submit New Job** - Paste your job script and click "Submit Job"
- **Cancel** - Click the red Cancel button to stop a job

### 4. GPUs
Real-time GPU monitoring:
- Temperature, utilization, memory usage for each GPU
- See which GPUs are busy or idle
- Organized by node

### 5. Storage
View disk space and NFS mounts (if configured)

### 6. Deploy Worker
Add new compute nodes to the cluster (admin use)

### 7. Settings
View and edit cluster configuration (admin use)

---

## How to Submit a Job

### Option 1: Using the Web UI

1. Go to the **Jobs** page
2. In the "Submit New Job" box, paste your job script
3. Click **Submit Job**

Example GPU job script:
```bash
#!/bin/bash
#SBATCH --job-name=my-gpu-job
#SBATCH --output=output-%j.log
#SBATCH --gres=gpu:1
#SBATCH --time=01:00:00

echo "Running on node: $SLURMD_NODENAME"
echo "GPUs available: $CUDA_VISIBLE_DEVICES"

# Your command here
python train.py
```

### Option 2: From Command Line (SSH)

SSH to the master node:
```bash
ssh bizon@172.30.1.205
```

Submit a job:
```bash
sbatch my_job.sh
```

Run an interactive GPU session:
```bash
srun --gres=gpu:1 --pty bash
```

---

## Common Job Commands

| Command | Description |
|---------|-------------|
| `squeue` | See all jobs in the queue |
| `sinfo` | See node status |
| `scancel <job_id>` | Cancel a job |
| `srun --gres=gpu:1 python script.py` | Run a quick GPU job |
| `sbatch script.sh` | Submit a batch job |

---

## Requesting GPUs

To use GPUs in your job, add this line to your script:

```bash
#SBATCH --gres=gpu:N
```

Where `N` is the number of GPUs you need (1-7 depending on node).

### Request Specific GPU Type
```bash
#SBATCH --gres=gpu:RTX-4090:2    # Request 2 RTX 4090s
#SBATCH --gres=gpu:H200-NVL:4    # Request 4 H200s
```

### Request Specific Node
```bash
#SBATCH --nodelist=worker1-gpu-4xH200
```

---

## Example Job Scripts

### Simple Python GPU Job
```bash
#!/bin/bash
#SBATCH --job-name=python-gpu
#SBATCH --output=output-%j.log
#SBATCH --gres=gpu:1
#SBATCH --time=02:00:00

source ~/miniconda3/bin/activate myenv
python train.py
```

### Multi-GPU Training
```bash
#!/bin/bash
#SBATCH --job-name=multi-gpu
#SBATCH --output=output-%j.log
#SBATCH --gres=gpu:4
#SBATCH --cpus-per-task=32
#SBATCH --mem=128G
#SBATCH --time=24:00:00

source ~/miniconda3/bin/activate pytorch
torchrun --nproc_per_node=4 train_distributed.py
```

### Interactive Session
```bash
# Request 1 GPU for 2 hours
srun --gres=gpu:1 --time=02:00:00 --pty bash

# Once connected, you can run commands interactively
python train.py
```

---

## Checking Job Status

### From Web UI
Go to **Jobs** page - you'll see all running and pending jobs

### From Command Line
```bash
# See your jobs
squeue -u $USER

# See all jobs
squeue

# See job details
scontrol show job <job_id>
```

---

## Troubleshooting

### Job stuck in PENDING
- Check if resources are available: `sinfo`
- Your job may be waiting for GPUs/CPUs to free up

### Job failed immediately
- Check the output file: `cat output-<job_id>.log`
- Make sure your script has `#!/bin/bash` at the top

### Can't connect to Web UI
- Make sure you're on the same network (172.30.1.x)
- Try: `http://172.30.1.205:5000`

### GPUs not visible in job
- Add `#SBATCH --gres=gpu:N` to your script
- Check `echo $CUDA_VISIBLE_DEVICES` in your job

---

## Need Help?

- **Web UI:** http://172.30.1.205:5000
- **SSH Access:** `ssh bizon@172.30.1.205`
- **Slurm Documentation:** https://slurm.schedmd.com/documentation.html
