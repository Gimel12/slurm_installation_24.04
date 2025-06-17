# Guide to Setting Up a Shared Filesystem with NFS

For a multi-node Slurm cluster to be efficient, users need seamless access to their files regardless of which node their job runs on. The standard way to achieve this is by sharing the `/home` directory from the controller node to all compute nodes using the Network File System (NFS).

This guide will walk you through setting up your controller (`dl`) as an NFS server and your compute nodes as NFS clients.

**Note**: For this to work, you must be able to resolve all node hostnames. Ensure your `/etc/hosts` file on all nodes is correct or that you have a working DNS setup.

--- 

## Step 1: Configure the NFS Server (on the Controller Node `dl`)

1.  **Install NFS Server Packages**:
    ```bash
    sudo apt update
    sudo apt install nfs-kernel-server
    ```

2.  **Configure the Shared Directory**:

    We will share the `/home` directory. To do this, you need to add an entry to the `/etc/exports` file. This file controls which directories are shared and who can access them.

    Open the file with a text editor:
    ```bash
    sudo nano /etc/exports
    ```

    Add the following line to the end of the file. This line tells the server to share `/home` with any client in the `192.168.1.0/24` subnet. **You must replace `192.168.1.0/24` with your actual network range**.

    ```
    /home    192.168.1.0/24(rw,sync,no_subtree_check)
    ```

    - `rw`: Allows clients to read and write to the directory.
    - `sync`: Ensures changes are written to disk before the server replies (safer).
    - `no_subtree_check`: Improves reliability.

3.  **Apply the Configuration**:

    After saving the `/etc/exports` file, run the following command to make the NFS server aware of the changes:
    ```bash
    sudo exportfs -a
    ```

4.  **Start and Enable the NFS Server**:
    ```bash
    sudo systemctl restart nfs-kernel-server
    sudo systemctl enable nfs-kernel-server
    ```

5.  **Adjust Firewall Rules (if applicable)**:

    If you are using a firewall (like `ufw`), you need to allow incoming traffic from your compute nodes to the NFS service.
    ```bash
    # Replace with your specific subnet
    sudo ufw allow from 192.168.1.0/24 to any port nfs
    ```

--- 

## Step 2: Configure NFS Clients (on each Compute Node)

Repeat these steps on every compute node you add to the cluster.

1.  **Install NFS Client Packages**:
    ```bash
    sudo apt update
    sudo apt install nfs-common
    ```

2.  **Mount the Shared Directory**:

    To ensure the shared directory is mounted automatically on boot, you need to add an entry to the `/etc/fstab` file.

    First, it's a good practice to back up the existing `/home` directory on the compute node in case it contains any files you need.
    ```bash
    # This moves the local home to home.bak. Only do this if you're sure you don't need local files.
    sudo mv /home /home.bak
    sudo mkdir /home
    ```

    Now, open `/etc/fstab`:
    ```bash
    sudo nano /etc/fstab
    ```

    Add the following line. **Replace `dl` with your controller's hostname or IP address**.
    ```
    # Mount /home from the Slurm controller
    dl:/home    /home    nfs    defaults    0    0
    ```

3.  **Mount the Filesystem**:

    You can now mount the directory without rebooting:
    ```bash
    sudo mount -a
    ```

--- 

## Step 3: Verify the Setup

1.  **On a compute node**, run the `df -h` command. You should see an entry showing that `dl:/home` is mounted on `/home`.

2.  **On a compute node**, try creating a file in your home directory:
    ```bash
    touch ~/test_from_compute_node.txt
    ```

3.  **On the controller node (`dl`)**, check if that file exists:
    ```bash
    ls ~/test_from_compute_node.txt
    ```

If you can see the file, your NFS shared filesystem is working correctly. Your Slurm cluster now has a unified home directory, making it much easier to manage jobs and data.
