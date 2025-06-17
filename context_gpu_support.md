---

---

# `Files`

[Setup_Cluster.zip](https://prod-files-secure.s3.us-west-2.amazonaws.com/f21a413b-85b1-4009-baa9-8babd05df455/a99b9ca6-ff26-4ee5-ae7a-63ecda3bed48/Setup_Cluster.zip)

# Important notes

Slurm works best with multithreading disable since this cause issues when sending multiple jobs. 

# Hardware and Software settings:

2x Machines 

`Machine 1` 

Hostname - dl1 

CPU - 64 

RAM - 256 

GPU - 2X 4090 

NETWORK - 1GB BOARD 

`Machine 2`

Hostanme - dl2 

CPU - 16 

RAM - 31 

GPU - 2X A6000 

NETWORK - 1GB BOARD 

`OS`

Ubuntu 22.04 - BizonOS - kernel 6.5 

Nvidia driver 545 and CUDA 12.3 

# Slurm installation on control node - `dl1`

```bash
Steps for configuring the Controller
Step 1 
insure each node details are in /etc/hosts file and it is copied to all hosts
Insure master node can ssh to all client node via passswordless authentication 
#Create the key
ssh-keygen
copy content of master node file (/root/.ssh/id_rsa.pub) to client node at file (/root/.ssh/authorized_keys)
Step 2 (For controller/Master )
 /usr/bin/bash /root/setup_controller.sh
#This will install slurm package and create user , add munge service and start slurmctld slurmd daemon
#Then we need to do configuration of slurm
In the /etc/slurm/slurm.conf chage these thing 
SlurmctldHost=dl1
GresTypes=gpu
NodeName=dl1 CPUs=128 Boards=1 SocketsPerBoard=1 CoresPerSocket=64 ThreadsPerCore=2 RealMemory=257000 Gres=gpu:rtxa4090:2
NodeName=dl2 CPUs=16 Boards=1 SocketsPerBoard=1 CoresPerSocket=8 ThreadsPerCore=2 RealMemory=64000 Gres=gpu:rtxa6000:2
#Run slurmd -C to get node configuration copy it to slurm.conf and mention the gpu after that
#Then add the nodes to the partition 
PartitionName=test Nodes=dl1,dl2 Default=YES MaxTime=INFINITE State=UP

#Also on each node define their gres.conf on each node base on gpu
NodeName=dl2 Name=gpu Type=rtxa6000 File=/dev/nvidia0
NodeName=dl2 Name=gpu Type=rtxa6000 File=/dev/nvidia1

Then restart controller and slurmd service 
systemctl restart slurmctld
systemctl restart slurmd
```

# Steps for configuring the client - `dl2`

```bash
Steps of Configuring the client node
/usr/bin/bash /root/setup_client.sh
#Copy the /etc/slurm and /etc/munge folder from master to this client noade after you have already mentioned the details about this node in slurm.conf file 
Then change the /etc/gres.conf file content as per the gpu 
#Restart the slurmd then
systemctl restart munge
systemctl restart slurmd
#IF you see the node in drain state you can put the node to idle state by running below command in controller
scontrol update nodename=dl1 state=idle

With sinfo -Nel you can get the node status

```

# Steps to configure an NFS shared file system

```bash
#Setting up the NFS on master node
# Install NFS server
sudo apt update
sudo apt install -y nfs-kernel-server
#Add the directory to export in /etc/exportfs file
#(base) root@dl1:/home/bizon/Setup_Cluster# cat /etc/exports
# /etc/exports: the access control list for filesystems which may be exported
#		to NFS clients.  See exports(5).
#
# Example for NFSv2 and NFSv3:
# /srv/homes       hostname1(rw,sync,no_subtree_check) hostname2(ro,sync,no_subtree_check)
#
# Example for NFSv4:
# /srv/nfs4        gss/krb5i(rw,sync,fsid=0,crossmnt,no_subtree_check)
# /srv/nfs4/homes  gss/krb5i(rw,sync,no_subtree_check)
#
/home *(rw,no_root_squash,sync,no_subtree_check)

# Restart the NFS server to reflect changes
sudo systemctl restart nfs-kernel-server

#Setting up nfs on client node
echo "Installing NFS client packages..."
    sudo apt-get update
    sudo apt-get install -y nfs-common
mv that folder original home as home 2 
mv /home /home2
mkdir /home
#Add the entery in /etc/fstab
(base) root@dl2:~# cat /etc/fstab 
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
# / was on /dev/nvme1n1p3 during installation
UUID=49eb5777-279d-4ad3-9a16-704c73098b02 /               ext4    errors=remount-ro 0       1
# /boot/efi was on /dev/nvme1n1p2 during installation
UUID=8A6E-E60D  /boot/efi       vfat    umask=0077      0       1
/swapfile                                 none            swap    sw              0       0
/dev/disk/by-uuid/ffd313ce-1896-4c82-94a2-7239599b9f47 /mnt/ffd313ce-1896-4c82-94a2-7239599b9f47 auto nosuid,nodev,nofail,x-gvfs-show 0 0
/dev/disk/by-uuid/883f9590-7dc3-4fac-ab30-67572652fa71 /mnt/883f9590-7dc3-4fac-ab30-67572652fa71 auto nosuid,nodev,nofail,x-gvfs-show 0 0
192.168.1.222:/home /home nfs4 defaults 0 0

Then run "mount -a"
```

# Submitting a GPU job

```bash
#Running on any gpu card
(base) root@dl1:/home/bizon/Setup_Cluster# sbatch  --gres=gpu:1 --wrap="cd /home/bizon/Downloads/gpu-burn/ ; ./gpu_burn -tc 36000 "
Submitted batch job 19
(base) root@dl1:/home/bizon/Setup_Cluster# squeue 
             JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
                19      test     wrap     root  R       0:02      1 dl2

#Running job on specific gpu card
(base) root@dl1:/home/bizon/Setup_Cluster# sbatch  --gres=gpu:rtxa4090:1 --wrap="cd /home/bizon/Downloads/gpu-burn/ ; ./gpu_burn -tc 36000 "
Submitted batch job 20
(base) root@dl1:/home/bizon/Setup_Cluster# squeue 
             JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
                19      test     wrap     root  R       1:15      1 dl2
                20      test     wrap     root  R       0:03      1 dl1

```

# Slurm commands

```bash
(base) root@dl1:/home/bizon/Setup_Cluster# sinfo -Nel
Mon Jun 17 17:01:08 2024
NODELIST   NODES PARTITION       STATE CPUS    S:C:T MEMORY TMP_DISK WEIGHT AVAIL_FE REASON              
dl1            1     test*       mixed 128    1:64:2 257000        0      1   (null) none                
dl2            1     test*       mixed 16      1:8:2  64000        0      1   (null) none                
(base) root@dl1:/home/bizon/Setup_Cluster# squeue 
             JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
                19      test     wrap     root  R       2:28      1 dl2
                20      test     wrap     root  R       1:16      1 dl1
(base) root@dl1:/home/bizon/Setup_Cluster# scontrol show node dl1
NodeName=dl1 Arch=x86_64 CoresPerSocket=64 
   CPUAlloc=2 CPUEfctv=128 CPUTot=128 CPULoad=2.93
   AvailableFeatures=(null)
   ActiveFeatures=(null)
   Gres=gpu:rtxa4090:2
   NodeAddr=dl1 NodeHostName=dl1 Version=22.05.9
   OS=Linux 6.5.0-15-generic #15~22.04.1-Ubuntu SMP PREEMPT_DYNAMIC Fri Jan 12 18:54:30 UTC 2 
   RealMemory=257000 AllocMem=0 FreeMem=248472 Sockets=1 Boards=1
   State=MIXED ThreadsPerCore=2 TmpDisk=0 Weight=1 Owner=N/A MCS_label=N/A
   Partitions=test 
   BootTime=2024-06-17T13:15:37 SlurmdStartTime=2024-06-17T15:36:28
   LastBusyTime=2024-06-17T16:58:43
   CfgTRES=cpu=128,mem=257000M,billing=128
   AllocTRES=cpu=2
   CapWatts=n/a
   CurrentWatts=0 AveWatts=0
   ExtSensorsJoules=n/s ExtSensorsWatts=0 ExtSensorsTemp=n/s

(base) root@dl1:/home/bizon/Setup_Cluster# scontrol show job 19
JobId=19 JobName=wrap
   UserId=root(0) GroupId=root(0) MCS_label=N/A
   Priority=4294901742 Nice=0 Account=(null) QOS=(null)
   JobState=RUNNING Reason=None Dependency=(null)
   Requeue=1 Restarts=0 BatchFlag=1 Reboot=0 ExitCode=0:0
   RunTime=00:02:48 TimeLimit=UNLIMITED TimeMin=N/A
   SubmitTime=2024-06-17T16:58:49 EligibleTime=2024-06-17T16:58:49
   AccrueTime=2024-06-17T16:58:49
   StartTime=2024-06-17T16:58:49 EndTime=Unknown Deadline=N/A
   SuspendTime=None SecsPreSuspend=0 LastSchedEval=2024-06-17T16:58:49 Scheduler=Main
   Partition=test AllocNode:Sid=dl1:131976
   ReqNodeList=(null) ExcNodeList=(null)
   NodeList=dl2
   BatchHost=dl2
   NumNodes=1 NumCPUs=2 NumTasks=1 CPUs/Task=1 ReqB:S:C:T=0:0:*:*
   TRES=cpu=2,node=1,billing=2
   Socks/Node=* NtasksPerN:B:S:C=0:0:*:* CoreSpec=*
   MinCPUsNode=1 MinMemoryNode=0 MinTmpDiskNode=0
   Features=(null) DelayBoot=00:00:00
   OverSubscribe=OK Contiguous=0 Licenses=(null) Network=(null)
   Command=(null)
   WorkDir=/home/bizon/Setup_Cluster
   StdErr=/home/bizon/Setup_Cluster/slurm-19.out
   StdIn=/dev/null
   StdOut=/home/bizon/Setup_Cluster/slurm-19.out
   Power=
   TresPerNode=gres:gpu:1
   
(base) root@dl1:/home/bizon/Setup_Cluster# squeue 
             JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
                19      test     wrap     root  R       3:56      1 dl2
                20      test     wrap     root  R       2:44      1 dl1
(base) root@dl1:/home/bizon/Setup_Cluster# scancel 19
(base) root@dl1:/home/bizon/Setup_Cluster# squeue 
             JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
                20      test     wrap     root  R       2:52      1 dl1
(base) root@dl1:/home/bizon/Setup_Cluster# scancel -u $USER
```

# Slurm everyday use commands

```bash
# Submit a gpu job 
sbatch  --gres=gpu:1 --wrap="cd /home/bizon/Downloads/gpu-burn/ ; ./gpu_burn -tc 36000 "

# check the job queue 
squeue

# Check the nodes 
sinfo -Nel

# Put a node in drain state - if we need to do maintenance on the node 
scontrol update NodeName=<node_name> State=DRAIN Reason="maintenance"

# Resume the node to a working state - IDLE 
scontrol update NodeName=<node_name> State=RESUME

# Restart the systemctl for slurm and munge 
systemctl restart slurmctld
systemctl restart slurmd
systemctl restart munge 

# Cancel a job 
scancel 'job number'

```

# Slurm troubleshooting common problems and logs

```bash
TODO 

```

# Web interface to launch jobs, stop them or modify cluster states

# Web interface to check cluster nodes information

- GPU usage per node
- GPU metrics

# Submitting a parallel job in two machines

# Network hardware to use for fast communication

# Submitting a DL workload like a llama3 8b model training on 2 nodes in parallel

- Here we need to check the speed between this two scenearios
- Scenario 1 - running the model on a single machine with 2gpus
- Scenario 2 - running the model on 2 machines with 4gpus
- We need to see the difference between running the job on 1 machine and when scaling to see if networking is a bottleneck and what improvement we get from it.

# New machine setup:

```bash
# First check the IP of the machine 

sudo vim /etc/hosts 

# Example: 
127.0.0.1       localhost
192.168.1.60

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
# Added by Docker Desktop
# To allow the same kube context to work on the host and the container:
127.0.0.1       kubernetes.docker.internal
192.168.1.222 dl1
192.168.1.254 dl2
# End of section
~                 

# We need to change or add the IPs of the machines for slurm where dl1 is the master node
	
# Then after this we need to modify the slurm.conf and gres.conf to add the machine specs

cd /etc/slurm/ 

# After modifying those files restart the slurm services
sudo systemctl restart slurmctld 
sudo systemctl restart slurmd 
sudo systemctl restart munge 

# Checking the Slurm to see if is available 
sinfo -Nel

# if the node is in drain state, then we need to bring it up. 
sudo scontrol update nodename=dl1 state=idle
sudo scontrol update partitionname=test state=up

# Check the logs if issues with slurm 
cat /var/log/slurmd.log

# Running a job to see if it works 
sbatch  --gres=gpu:1 --wrap="cd /home/bizon/Downloads/gpu-burn/ ; ./gpu_burn -tc 36000 "

# Check the job running 
squeue

# Cancel a job 
scancel 'job number'
```