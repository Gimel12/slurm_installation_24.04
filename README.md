# Automated Slurm Installation for Single-Node with GPU Support

This repository contains a set of scripts to automate the installation and configuration of a single-node Slurm cluster on Ubuntu 24.04. The installation is designed to be modular and hardware-aware, automatically detecting and configuring the system's CPUs, memory, and NVIDIA GPUs.

## Features

- **Automated Installation**: Installs Slurm 24.05.2 and its dependencies from source.
- **Hardware-Aware**: Automatically detects CPU cores, system memory, and the number and model of NVIDIA GPUs.
- **Dynamic Configuration**: Generates `slurm.conf`, `gres.conf`, and `cgroup.conf` based on the detected hardware.
- **GPU Support**: Configures Slurm's Generic Resource Scheduling (GRES) to manage and schedule jobs on GPUs, including specifying the GPU model type.
- **Cleanup**: Includes a function to purge previous Slurm installations to ensure a clean setup.
- **Verification Script**: Provides a ready-to-use sbatch script to test the GPU allocation and functionality.

## Prerequisites

Before running the installation script, ensure your system meets the following requirements:

1.  **Operating System**: Ubuntu 24.04 LTS.
2.  **NVIDIA Drivers**: A compatible NVIDIA driver must be installed and functional. You can verify this by running `nvidia-smi`.
3.  **Internet Connection**: Required to download the Slurm source code and dependencies.
4.  **Root Privileges**: The script requires `sudo` access to install packages and configure system services.

## Scripts

- `install.sh`: The main installation script. It performs the cleanup, dependency installation, Slurm build, and configuration.
- `run_gpu_burn_test.sbatch`: A Slurm batch script to verify that GPU resources are correctly allocated and functional.

## Installation

1.  **Clone the repository or download the scripts** to your target machine.

2.  **Make the installation script executable**:
    ```bash
    chmod +x install.sh
    ```

3.  **Run the installation script**:
    ```bash
    sudo ./install.sh
    ```
    The script will run non-interactively, performing all necessary steps automatically.

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

## Web Interface

This project includes a lightweight web interface built with Flask to provide an intuitive way to manage the Slurm cluster. It allows users to view node and job status, submit new jobs, and cancel existing jobs from a web browser.

### Running the Web Interface

1.  **Navigate to the UI directory**:
    ```bash
    cd slurm_web_ui
    ```

2.  **Install Python Dependencies**:
    ```bash
    pip install -r requirements.txt
    ```

3.  **Run the Flask Application**:
    ```bash
    python3 app.py
    ```

4.  **Access the Dashboard**:

    Once the server is running, you can access the web UI by opening your browser and navigating to:
    [http://localhost:5000](http://localhost:5000)

