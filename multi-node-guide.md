# Guide to Scaling to a Multi-Node Slurm Cluster

This guide provides the steps to add a new compute node to your existing Slurm cluster. It assumes your current machine (`dl`) is the designated controller node.

## Core Concepts

- **Controller Node**: Manages the cluster, schedules jobs, and maintains state. Runs `slurmctld`.
- **Compute Nodes**: Execute jobs as directed by the controller. They only run `slurmd`.
- **Shared Configuration**: All nodes **must** share identical `slurm.conf`, `gres.conf`, and `cgroup.conf` files.
- **Shared Authentication**: All nodes **must** use the same `/etc/munge/munge.key`.
- **Network & Users**: All nodes must be on the same network, be able to resolve each other's hostnames, and have consistent user/group IDs (UIDs/GIDs).
- **Shared Home Directories**: It is highly recommended to set up a shared filesystem (like NFS) for `/home` so users can access their files from any node.

--- 

## Step 1: Prepare the Controller Node (`dl`)

First, we need to update the Slurm configuration on your controller node to make it aware of the new compute node.

Let's assume the hostname of your new compute node is `new-compute-01`.

1.  **Update `/etc/slurm/slurm.conf`**:

    You need to add a `NodeName` entry for each new node. The `install.sh` script can help generate the hardware details for the new node. Run it on the new node, note the `CPUs`, `RealMemory`, and `Gres` values it would use, and then manually add a line for it in the controller's `slurm.conf`.

    Your `slurm.conf`'s node definitions would change from this:
    ```
    # COMPUTE NODES
    NodeName=dl CPUs=20 RealMemory=95819 Gres=gpu:NVIDIA_GeForce_RTX_5090:1 State=UNKNOWN
    PartitionName=gpu Nodes=dl Default=YES MaxTime=INFINITE State=UP
    ```

    To this (assuming `new-compute-01` has similar hardware):
    ```
    # COMPUTE NODES
    NodeName=dl CPUs=20 RealMemory=95819 Gres=gpu:NVIDIA_GeForce_RTX_5090:1 State=UNKNOWN
    NodeName=new-compute-01 CPUs=20 RealMemory=95819 Gres=gpu:NVIDIA_GeForce_RTX_5090:1 State=UNKNOWN
    PartitionName=gpu Nodes=dl,new-compute-01 Default=YES MaxTime=INFINITE State=UP
    ```

2.  **Update `/etc/slurm/gres.conf`**:

    Add entries for the GPUs on the new node.
    ```
    # Existing entry
    NodeName=dl Name=gpu Type=NVIDIA_GeForce_RTX_5090 File=/dev/nvidia0
    # Entry for new node
    NodeName=new-compute-01 Name=gpu Type=NVIDIA_GeForce_RTX_5090 File=/dev/nvidia0
    ```

3.  **Restart the Controller Daemon**:

    After saving the configuration changes, restart `slurmctld` to apply them.
    ```bash
    sudo systemctl restart slurmctld
    ```

--- 

## Step 2: Set Up the New Compute Node (`new-compute-01`)

1.  **Run the Installer**:

    Copy the `install.sh` script to the new node and run it. This will install all the necessary dependencies, create the `slurm` user, and build the Slurm binaries.
    ```bash
    chmod +x install.sh
    sudo ./install.sh
    ```

2.  **Copy Configuration from Controller**:

    The `install.sh` script will have created a default configuration for a single node. **You must overwrite these files** with the configuration from your controller node (`dl`).

    From the new compute node, run:
    ```bash
    # Replace 'dl' with your controller's hostname or IP if needed
    sudo scp dl:/etc/slurm/slurm.conf /etc/slurm/slurm.conf
    sudo scp dl:/etc/slurm/gres.conf /etc/slurm/gres.conf
    sudo scp dl:/etc/slurm/cgroup.conf /etc/slurm/cgroup.conf
    ```

3.  **Copy the Munge Key**:

    This is the most critical step for authentication. Copy the key from the controller and ensure its permissions are correct.
    ```bash
    sudo scp dl:/etc/munge/munge.key /etc/munge/munge.key
    sudo chown munge:munge /etc/munge/munge.key
    sudo chmod 400 /etc/munge/munge.key
    ```

4.  **Start Services on the Compute Node**:

    Start and enable the `munge` and `slurmd` services. **Do not** start `slurmctld` on a compute node.
    ```bash
    sudo systemctl restart munge
    sudo systemctl enable munge

    sudo systemctl restart slurmd
    sudo systemctl enable slurmd
    ```

--- 

## Step 3: Verify the Cluster

Go back to your controller node (`dl`) and check the status of the cluster.

1.  **Check Node Status**:
    ```bash
    sinfo
    ```
    You should now see `new-compute-01` in the node list. It may take a minute to register. Initially, it might appear in a `down` or `drain` state. 

2.  **Resume the Node (if needed)**:
    If the node is drained, you can bring it online with:
    ```bash
    sudo scontrol update NodeName=new-compute-01 State=IDLE
    ```

Your multi-node cluster is now ready. You can submit jobs, and the controller will schedule them on either `dl` or `new-compute-01` based on resource availability.
