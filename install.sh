#!/bin/bash

# Global variables
SLURM_VERSION="24.05.2"
slurm_accounting_support=0
without_interaction="false"
mysql_root_password=""
without_interaction_parameter="false"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

cleanupPreviousInstall() {
    echo "Stopping any running Slurm services..."
    sudo systemctl stop slurmctld slurmd slurmdbd munge &>/dev/null || true

    echo "Removing old Slurm installation files..."
    # These paths cover typical source install locations
    sudo rm -rf /usr/sbin/slurm* /usr/bin/sinfo /usr/bin/srun /usr/bin/sbatch /usr/bin/scontrol /usr/bin/sacct
    sudo rm -rf /usr/lib/slurm
    sudo rm -rf /usr/lib64/slurm
    sudo rm -rf /etc/slurm
    sudo rm -rf /var/log/slurm*
    sudo rm -rf /var/spool/slurm
    # Remove old systemd files if they exist
    sudo rm -f /etc/systemd/system/slurm*
    sudo systemctl daemon-reload
    echo "Cleanup complete."
}

welcomeMessage() {
    echo -e "${GREEN}###################################################"
    echo -e "Welcome to the SLURM Installation Script for Ubuntu 24.04"
    echo -e "This script will perform a single-node install with GPU support."
    echo -e "###################################################${NC}"
    echo "You can customize the SLURM version by setting SLURM_VERSION before running the script"
    echo "Press enter to continue."
    if ! $without_interaction; then
        read p
    fi
}

checkUbuntuVersion() {
    ubuntu_version=$(lsb_release -rs)
    if [ "$ubuntu_version" != "24.04" ]; then
        echo -e "${RED}This script is designed for Ubuntu 24.04 only. Detected version: $ubuntu_version${NC}"
        exit 1
    fi
}

createRequiredUsers() {
    echo "Creating required users..."
    export MUNGEUSER=966
    sudo groupadd -g $MUNGEUSER munge
    if ! id "munge" &> /dev/null; then
        sudo useradd -m -c "MUNGE Uid 'N' Gid Emporium" -d /var/lib/munge -u $MUNGEUSER -g munge -s /sbin/nologin munge
    fi

    export SLURMUSER=967
    if ! getent group slurm &> /dev/null; then
        sudo groupadd -g $SLURMUSER slurm
    fi
    sudo useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURMUSER -g slurm -s /bin/bash slurm
}

installDependencies() {
    echo "Installing dependencies..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        bzip2 \
        python3 \
        gcc \
        openssl \
        numactl \
        hwloc \
        lua5.3 \
        make \
        ruby \
        ruby-dev \
        libmunge-dev \
        libpam0g-dev \
        libdbus-1-dev \
        rng-tools \
        mariadb-server \
        libmariadbd-dev \
        libmariadb3 \
        munge \
        libmunge-dev \
        libmunge2 \
        libnvidia-ml-dev # For GRES GPU support
}

setupRngTools() {
    echo "Setting up RNG tools..."
    sudo rngd -r /dev/urandom
}

setupMunge() {
    echo "Setting up Munge..."
    sudo /usr/sbin/mungekey -f
    sudo sh -c "dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key"
    sudo chown munge: /etc/munge/munge.key
    sudo chmod 400 /etc/munge/munge.key
    sudo systemctl enable munge
    sudo systemctl start munge
}

buildSlurm() {
    echo "Building SLURM..."
    mkdir -p slurm-tmp
    cd slurm-tmp

    wget --no-check-certificate https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
    if [ $? != 0 ]; then
        echo "Failed to download SLURM. Exiting..."
        exit 1
    fi

    tar jxvf slurm-${SLURM_VERSION}.tar.bz2
    cd slurm-${SLURM_VERSION}

    ./configure --prefix=/usr \
                --sysconfdir=/etc/slurm \
                --enable-pam \
                --with-pam_dir=/lib/x86_64-linux-gnu/security/ \
                --without-shared-libslurm

    make
    make contrib
    sudo make install
    cd ../../
    rm -rf slurm-tmp
}

setupSlurm() {
    echo "Setting up SLURM configuration with auto-detected hardware..."
    HOST=$(hostname)

    # Use slurmd to get accurate hardware info
    # This is run after build, so the binary exists.
    HW_INFO=$(/usr/sbin/slurmd -C)
    CPUS=$(echo "$HW_INFO" | grep -o 'CPUs=[0-9]*' | cut -d'=' -f2)
    REAL_MEMORY=$(echo "$HW_INFO" | grep -o 'RealMemory=[0-9]*' | cut -d'=' -f2)

    # Get GPU info
    GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader 2>/dev/null || echo 0)

    if [ -z "$GPU_COUNT" ] || ! [[ "$GPU_COUNT" =~ ^[0-9]+$ ]] || [ "$GPU_COUNT" -eq 0 ]; then
        echo -e "${RED}No NVIDIA GPUs detected. Continuing without GPU support.${NC}"
        GRES_CONFIG=""
        GRES_TYPES_CONFIG=""
        PARTITION_NAME="cpu"
    else
        # Sanitize GPU name for Slurm config (e.g., "NVIDIA GeForce RTX 5090" -> "NVIDIA_GeForce_RTX_5090")
        GPU_MODEL=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | head -n 1 | tr ' ' '_')
        echo "Detected $GPU_COUNT GPU(s) of type '$GPU_MODEL'. Configuring GRES..."
        GRES_CONFIG="Gres=gpu:$GPU_MODEL:$GPU_COUNT"
        GRES_TYPES_CONFIG="GresTypes=gpu"
        PARTITION_NAME="gpu"
    fi

    sudo mkdir -p /etc/slurm/

    # Create slurm.conf
    cat << EOF | sudo tee /etc/slurm/slurm.conf
# slurm.conf automatically generated for host: $HOST
ClusterName=cluster
SlurmctldHost=$HOST
MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=1
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurm/slurmd
SlurmUser=slurm
StateSaveLocation=/var/spool/slurm
SwitchType=switch/none
TaskPlugin=task/affinity
# SCHEDULING
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
# LOGGING AND ACCOUNTING
AccountingStorageType=accounting_storage/none
JobAcctGatherType=jobacct_gather/none
# GRES CONFIG
$GRES_TYPES_CONFIG
# COMPUTE NODES
NodeName=$HOST CPUs=$CPUS RealMemory=$REAL_MEMORY $GRES_CONFIG State=UNKNOWN
PartitionName=$PARTITION_NAME Nodes=$HOST Default=YES MaxTime=INFINITE State=UP
EOF

    # Create gres.conf if GPUs are present
    if [ -n "$GRES_CONFIG" ]; then
        echo "Creating gres.conf..."
        GRES_CONF_LINES=""
        for (( i=0; i<$GPU_COUNT; i++ )); do
            GRES_CONF_LINES+="NodeName=$HOST Name=gpu Type=$GPU_MODEL File=/dev/nvidia$i\n"
        done
        echo -e "$GRES_CONF_LINES" | sudo tee /etc/slurm/gres.conf
    fi

    # Create cgroup.conf
    cat << EOF | sudo tee /etc/slurm/cgroup.conf
CgroupPlugin=cgroup/v2
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
EOF

    if [ "$slurm_accounting_support" == "1" ]; then
        setupAccounting
    fi
}

setupAccounting() {
    echo "Setting up SLURM accounting..."
    StorageType=accounting_storage/mysql
    DbdHost=localhost
    StorageHost=$DbdHost
    StorageLoc=slurm_acct_db
    StorageUser=slurm
    SlurmUser=$StorageUser
    random_mysql_password=$(tr -dc '0-9a-zA-Z@' < /dev/urandom | head -c 20)
    StoragePass=$random_mysql_password
    StoragePort=3306

    createMysqlDatabase $StorageLoc $StorageUser $StoragePass

    cat <<EOF | sudo tee /etc/slurm/slurmdbd.conf
StorageType=$StorageType
DbdAddr=$DbdHost
DbdHost=$DbdHost
StorageHost=$StorageHost
StorageLoc=$StorageLoc
StorageUser=$StorageUser
SlurmUser=$SlurmUser
StoragePass=$StoragePass
StoragePort=$StoragePort
LogFile=/var/log/slurmdbd.log
EOF

    sudo sed -i 's/AccountingStorageType=accounting_storage\/none/AccountingStorageType=accounting_storage\/slurmdbd/' /etc/slurm/slurm.conf

    # Configure MariaDB for SLURM
    total_memory=$(free -m | awk '/^Mem:/{print $2}')
    innodb_buffer_percent=50
    innodb_buffer_pool_size=$((total_memory * innodb_buffer_percent / 100))
    cat <<EOF | sudo tee /etc/mysql/mariadb.conf.d/99-slurm.cnf
[mariadb]
innodb_lock_wait_timeout=900
innodb_log_file_size=128M
max_allowed_packet=32M
innodb_buffer_pool_size=${innodb_buffer_pool_size}M
EOF

    sudo systemctl restart mariadb
}

createMysqlDatabase() {
    StorageLoc=$1
    StorageUser=$2
    StoragePass=$3

    if [ -z "$mysql_root_password" ]; then
        echo "Please enter MySQL root password (leave empty if none):"
        read mysql_root_password
    fi

    export MYSQL_PWD=$mysql_root_password
    if sudo mysql -u root -e "SELECT 1" &> /dev/null; then
        if ! sudo mysql -u root -e "use $StorageLoc" 2> /dev/null; then
            sudo mysql -u root -e "CREATE DATABASE $StorageLoc;"
            sudo mysql -u root -e "CREATE USER '$StorageUser'@'localhost' IDENTIFIED BY '$StoragePass';"
            sudo mysql -u root -e "GRANT ALL PRIVILEGES ON $StorageLoc.* TO '$StorageUser'@'localhost';"
            sudo mysql -u root -e "FLUSH PRIVILEGES;"
        fi
    else
        echo "Failed to connect to MySQL. Please check your root password."
        exit 1
    fi
    unset MYSQL_PWD
}

createRequiredFiles() {
    echo "Creating required files and directories..."
    sudo mkdir -p /var/spool/slurm
    sudo mkdir -p /var/spool/slurm/slurmctld
    sudo mkdir -p /var/spool/slurm/cluster_state
    sudo touch /var/log/slurmctld.log
    sudo touch /var/log/slurm_jobacct.log /var/log/slurm_jobcomp.log
}

fixingPermissions() {
    echo "Setting up permissions..."
    sudo chown -R slurm:slurm /etc/slurm
    sudo chmod 600 /etc/slurm/slurmdbd.conf
    sudo chown slurm:slurm /var/spool/slurm
    sudo chmod 755 /var/spool/slurm
    sudo chown slurm:slurm /var/spool/slurm/slurmctld
    sudo chmod 755 /var/spool/slurm/slurmctld
    sudo chown slurm:slurm /var/spool/slurm/cluster_state
    sudo chown slurm:slurm /var/log/slurmctld.log
    sudo chown slurm: /var/log/slurm_jobacct.log /var/log/slurm_jobcomp.log
}

setupSystemd() {
    echo "Setting up systemd services..."
    cat <<EOF | sudo tee /etc/systemd/system/slurmctld.service
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
ConditionPathExists=/etc/slurm/slurm.conf

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmctld
ExecStart=/usr/sbin/slurmctld \$SLURMCTLD_OPTIONS
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/slurmctld.pid

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF | sudo tee /etc/systemd/system/slurmdbd.service
[Unit]
Description=Slurm DBD accounting daemon
Wants=network.target munge.service slurmctld.service
After=network.target munge.service slurmctld.service
ConditionPathExists=/etc/slurm/slurmdbd.conf

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmdbd
ExecStart=/usr/sbin/slurmdbd \$SLURMDBD_OPTIONS
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/slurmdbd.pid

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF | sudo tee /etc/systemd/system/slurmd.service
[Unit]
Description=Slurm node daemon
After=network.target munge.service
ConditionPathExists=/etc/slurm/slurm.conf

[Service]
Type=forking
EnvironmentFile=-/etc/sysconfig/slurmd
ExecStart=/usr/sbin/slurmd -d /usr/sbin/slurmstepd \$SLURMD_OPTIONS
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/var/run/slurmd.pid
KillMode=process
LimitNOFILE=51200
LimitMEMLOCK=infinity
LimitSTACK=infinity

[Install]
WantedBy=multi-user.target
EOF
}

enableSystemdServices() {
    echo "Enabling and starting services..."
    sudo systemctl daemon-reload
    if [ "$slurm_accounting_support" == "1" ]; then
        sudo systemctl enable --now slurmdbd
        sleep 5
    fi
    sudo systemctl enable --now slurmctld
    sleep 5
    sudo systemctl enable --now slurmd
}

testSlurm() {
    echo "Testing SLURM installation..."
    sleep 5
    echo "Running sinfo..."
    sinfo
    echo "Running scontrol show partition..."
    scontrol show partition
    echo "Running slurmd -C..."
    slurmd -C
    echo "Running srun hostname..."
    srun hostname
}

askSlurmAccountingSupport() {
    if ! $without_interaction; then
        valid_answer=false
        while ! $valid_answer; do
            echo -e "${GREEN}##########################################################################"
            echo "Do you want to enable Slurm accounting support? [yes/no]"
            echo -e "##########################################################################${NC}"
            read answer

            answer_lowercase=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

            if [ "$answer_lowercase" == "y" ] || [ "$answer_lowercase" == "yes" ]; then
                slurm_accounting_support=1
                valid_answer=true
            elif [ "$answer_lowercase" == "n" ] || [ "$answer_lowercase" == "no" ]; then
                slurm_accounting_support=0
                valid_answer=true
            else
                echo "Invalid input!"
            fi
        done
    fi
}

main() {
    cleanupPreviousInstall
    welcomeMessage
    checkUbuntuVersion
    askSlurmAccountingSupport
    createRequiredUsers
    installDependencies
    setupRngTools
    setupMunge
    buildSlurm
    setupSlurm
    createRequiredFiles
    fixingPermissions
    setupSystemd
    enableSystemdServices
    testSlurm
    echo -e "${GREEN}SLURM installation completed successfully!${NC}"
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --without-interaction)
            without_interaction=true
            shift
            ;;
        --slurm-accounting-support=true)
            slurm_accounting_support=1
            shift
            ;;
        --slurm-accounting-support=false)
            slurm_accounting_support=0
            shift
            ;;
        --mysql-password=*)
            mysql_root_password="${arg#*=}"
            shift
            ;;
        *)
            echo "Unknown parameter: $arg"
            exit 1
            ;;
    esac
done

main 