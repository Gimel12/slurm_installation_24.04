#!/bin/bash
#
#SBATCH --job-name=gpu-burn-test    # Name of the job
#SBATCH --output=gpu-burn-%j.out    # Standard output file
#SBATCH --error=gpu-burn-%j.err     # Standard error file
#SBATCH --partition=gpu             # Partition to submit to
#SBATCH --gres=gpu:1                # Request 1 GPU
#SBATCH --time=00:02:00             # Job time limit (2 minutes)

echo "======================================================"
echo "## Slurm GPU Burn Test                            ##"
echo "======================================================"
echo "  Job ID: $SLURM_JOB_ID"
echo "  Job Name: $SLURM_JOB_NAME"
echo "  Node: $(hostname)"
echo "  Partition: $SLURM_JOB_PARTITION"
echo "  Requested GPUs: $SLURM_GPUS_ON_NODE"
echo "  Visible CUDA Devices: $CUDA_VISIBLE_DEVICES"
echo "------------------------------------------------------"

# IMPORTANT: This path must be correct on the target machine.
GPU_BURN_DIR="/home/bizon/Downloads/gpu-burn"

if [ ! -f "$GPU_BURN_DIR/gpu_burn" ]; then
    echo "Error: 'gpu_burn' executable not found at $GPU_BURN_DIR/gpu_burn"
    echo "Please download and build it first."
    exit 1
fi

cd "$GPU_BURN_DIR" || exit

# Run the GPU burn test for 30 seconds
echo "Starting gpu_burn for 30 seconds..."
./gpu_burn 30

echo "------------------------------------------------------"
echo "GPU burn test finished."
echo "======================================================"
