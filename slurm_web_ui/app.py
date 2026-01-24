"""
Slurm Cluster Management Web UI
A comprehensive dashboard for monitoring and managing Slurm clusters
"""

import subprocess
import pandas as pd
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from flask_socketio import SocketIO, emit
import tempfile
import os
import socket
import json
import threading
import time
from datetime import datetime
import psutil
import paramiko
import select

app = Flask(__name__)
app.secret_key = os.urandom(24)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

# Store deployment status
deployment_status = {}

# Store active SSH sessions for terminals
ssh_sessions = {}

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

def run_command(command, timeout=30):
    """Executes a shell command and returns its output."""
    try:
        result = subprocess.run(
            command, shell=True, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=timeout
        )
        return result.stdout, None
    except subprocess.CalledProcessError as e:
        return None, e.stderr
    except subprocess.TimeoutExpired:
        return None, "Command timed out"
    except Exception as e:
        return None, str(e)

def run_slurm_command(command):
    """Wrapper for Slurm commands."""
    return run_command(command)

# ============================================================
# CLUSTER STATISTICS
# ============================================================

def get_cluster_stats():
    """Gather comprehensive cluster statistics."""
    stats = {
        'total_nodes': 0,
        'idle_nodes': 0,
        'allocated_nodes': 0,
        'down_nodes': 0,
        'total_cpus': 0,
        'allocated_cpus': 0,
        'total_memory': 0,
        'running_jobs': 0,
        'pending_jobs': 0,
        'completed_jobs_today': 0,
        'cluster_status': 'Online',
        'uptime': 'N/A',
        'master_node': socket.gethostname(),
        'total_gpus': 0,
        'allocated_gpus': 0
    }
    
    # Get node info
    output, _ = run_slurm_command("sinfo -h -o '%D %C %m %T %G'")
    if output:
        for line in output.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 4:
                node_count = int(parts[0])
                stats['total_nodes'] += node_count
                cpu_info = parts[1].split('/')
                if len(cpu_info) == 4:
                    stats['allocated_cpus'] += int(cpu_info[0])
                    stats['total_cpus'] = int(cpu_info[3])
                try:
                    stats['total_memory'] = round(int(parts[2]) / 1024, 1)
                except:
                    pass
                state = parts[3].lower()
                if 'idle' in state:
                    stats['idle_nodes'] += node_count
                elif 'alloc' in state or 'mix' in state:
                    stats['allocated_nodes'] += node_count
                elif 'down' in state or 'drain' in state:
                    stats['down_nodes'] += node_count
                # GPU info
                if len(parts) >= 5 and 'gpu' in parts[4].lower():
                    try:
                        gpu_part = parts[4].split(':')
                        if len(gpu_part) >= 2:
                            stats['total_gpus'] += int(gpu_part[-1].split('(')[0])
                    except:
                        pass
    
    # Get job counts
    output, _ = run_slurm_command("squeue -h -t running | wc -l")
    if output:
        stats['running_jobs'] = int(output.strip())
    
    output, _ = run_slurm_command("squeue -h -t pending | wc -l")
    if output:
        stats['pending_jobs'] = int(output.strip())
    
    # Get uptime
    output, _ = run_command("uptime -p")
    if output:
        stats['uptime'] = output.strip().replace('up ', '')
    
    # Check cluster status
    output, error = run_slurm_command("scontrol ping")
    if error or (output and 'UP' not in str(output)):
        stats['cluster_status'] = 'Degraded'
    
    return stats

# ============================================================
# NODE INFORMATION
# ============================================================

def get_nodes_detailed():
    """Get detailed information about all nodes including GPUs."""
    nodes = []
    output, _ = run_slurm_command("scontrol show nodes")
    if not output:
        return nodes
    
    current_node = {}
    for line in output.split('\n'):
        line = line.strip()
        if line.startswith('NodeName='):
            if current_node:
                nodes.append(current_node)
            current_node = {'gpus': [], 'nfs_mounts': []}
        
        for item in line.split():
            if '=' in item:
                key, value = item.split('=', 1)
                current_node[key] = value
    
    if current_node:
        nodes.append(current_node)
    
    # Enhance with GPU info
    for node in nodes:
        node_name = node.get('NodeName', '')
        gres = node.get('Gres', '')
        if 'gpu' in gres.lower():
            parts = gres.split(':')
            if len(parts) >= 2:
                gpu_type = parts[1] if len(parts) > 2 else 'GPU'
                gpu_count = parts[-1].split('(')[0]
                node['gpu_type'] = gpu_type
                node['gpu_count'] = gpu_count
        
        # Parse memory
        try:
            real_mem = int(node.get('RealMemory', 0))
            node['memory_gb'] = round(real_mem / 1024, 1)
        except:
            node['memory_gb'] = 0
        
        # Parse CPU load
        try:
            cpu_load = float(node.get('CPULoad', 0))
            node['cpu_load_percent'] = round(cpu_load * 100 / int(node.get('CPUTot', 1)), 1)
        except:
            node['cpu_load_percent'] = 0
    
    return nodes

def get_node_gpu_info(node_name):
    """Get GPU information for a specific node via SSH or local command."""
    gpu_info = []
    
    if node_name == socket.gethostname():
        # Local node
        output, _ = run_command("nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null")
    else:
        # Remote node - would need SSH
        output = None
    
    if output:
        for line in output.strip().split('\n'):
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 6:
                gpu_info.append({
                    'index': parts[0],
                    'name': parts[1],
                    'memory_total': parts[2],
                    'memory_used': parts[3],
                    'utilization': parts[4],
                    'temperature': parts[5]
                })
    
    return gpu_info

# ============================================================
# STORAGE / NFS INFORMATION
# ============================================================

def get_storage_info():
    """Get NFS and storage mount information."""
    storage = []
    
    # Get NFS mounts
    output, _ = run_command("mount | grep nfs")
    if output:
        for line in output.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 3:
                storage.append({
                    'type': 'NFS',
                    'source': parts[0],
                    'mount_point': parts[2],
                    'options': parts[4] if len(parts) > 4 else ''
                })
    
    # Get NFS exports (if this is the server)
    output, _ = run_command("cat /etc/exports 2>/dev/null")
    nfs_exports = []
    if output:
        for line in output.strip().split('\n'):
            if line and not line.startswith('#'):
                nfs_exports.append(line)
    
    # Get disk usage for important mounts
    disk_usage = []
    for mount in ['/home', '/tmp', '/']:
        try:
            usage = psutil.disk_usage(mount)
            disk_usage.append({
                'mount': mount,
                'total': round(usage.total / (1024**3), 1),
                'used': round(usage.used / (1024**3), 1),
                'free': round(usage.free / (1024**3), 1),
                'percent': usage.percent
            })
        except:
            pass
    
    return {
        'nfs_mounts': storage,
        'nfs_exports': nfs_exports,
        'disk_usage': disk_usage
    }

# ============================================================
# JOB MANAGEMENT
# ============================================================

def get_jobs():
    """Get all jobs with detailed information."""
    jobs = []
    output, _ = run_slurm_command("squeue -o '%i|%P|%j|%u|%T|%M|%D|%R|%C|%m' --noheader")
    if output:
        for line in output.strip().split('\n'):
            parts = line.split('|')
            if len(parts) >= 8:
                jobs.append({
                    'job_id': parts[0].strip(),
                    'partition': parts[1].strip(),
                    'name': parts[2].strip(),
                    'user': parts[3].strip(),
                    'state': parts[4].strip(),
                    'time': parts[5].strip(),
                    'nodes': parts[6].strip(),
                    'reason': parts[7].strip(),
                    'cpus': parts[8].strip() if len(parts) > 8 else 'N/A',
                    'memory': parts[9].strip() if len(parts) > 9 else 'N/A'
                })
    return jobs

# ============================================================
# WORKER DEPLOYMENT
# ============================================================

def deploy_worker_thread(node_ip, node_hostname, username, password, deploy_id):
    """Background thread for deploying a worker node."""
    global deployment_status
    
    deployment_status[deploy_id] = {
        'status': 'running',
        'progress': 0,
        'message': 'Starting deployment...',
        'logs': []
    }
    
    def update_status(progress, message, log_entry=None):
        deployment_status[deploy_id]['progress'] = progress
        deployment_status[deploy_id]['message'] = message
        if log_entry:
            deployment_status[deploy_id]['logs'].append(f"[{datetime.now().strftime('%H:%M:%S')}] {log_entry}")
    
    try:
        import paramiko
        
        update_status(5, 'Connecting to node...', f'Connecting to {node_ip}')
        
        # Connect via SSH
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(node_ip, username=username, password=password, timeout=30)
        
        update_status(10, 'Connected, uploading deployment script...', 'SSH connection established')
        
        # Upload the deployment script
        sftp = ssh.open_sftp()
        
        # Get the path to deploy script
        script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        deploy_script = os.path.join(script_dir, 'deploy_compute_node_arm64.sh')
        
        if not os.path.exists(deploy_script):
            deploy_script = os.path.join(script_dir, 'deploy_compute_node.sh')
        
        # Also need the config package
        config_package = '/home/slurm_cluster_config.tar.gz'
        
        update_status(15, 'Uploading files...', 'Uploading deployment script and config')
        
        sftp.put(deploy_script, '/tmp/deploy_compute_node.sh')
        if os.path.exists(config_package):
            sftp.put(config_package, '/tmp/slurm_cluster_config.tar.gz')
        
        sftp.close()
        
        update_status(20, 'Running deployment script...', 'Starting Slurm installation (this may take several minutes)')
        
        # Run the deployment script with sudo password via stdin
        stdin, stdout, stderr = ssh.exec_command(
            'cd /tmp && chmod +x deploy_compute_node.sh && echo "{}" | sudo -S bash deploy_compute_node.sh 2>&1'.format(password),
            timeout=1800  # 30 minutes timeout
        )
        
        # Read output progressively
        progress = 20
        for line in iter(stdout.readline, ''):
            line = line.strip()
            if line:
                update_status(min(progress, 90), f'Installing: {line[:50]}...', line)
                if 'Installing' in line or 'Building' in line:
                    progress = min(progress + 5, 85)
        
        exit_status = stdout.channel.recv_exit_status()
        
        if exit_status == 0:
            update_status(90, 'Adding node to cluster...', 'Deployment successful, updating cluster config')
            
            # Add the node to slurm.conf on master
            # Get node hardware info
            stdin, stdout, stderr = ssh.exec_command('echo "{}" | sudo -S /usr/sbin/slurmd -C 2>/dev/null'.format(password))
            hw_info = stdout.read().decode()
            
            # Parse hardware info
            cpus = '4'
            memory = '8000'
            for part in hw_info.split():
                if part.startswith('CPUs='):
                    cpus = part.split('=')[1]
                elif part.startswith('RealMemory='):
                    memory = part.split('=')[1]
            
            # Update master's slurm.conf with NodeAddr for proper routing
            node_line = f"NodeName={node_hostname} NodeAddr={node_ip} CPUs={cpus} RealMemory={memory} State=UNKNOWN"
            
            # Read current config
            with open('/etc/slurm/slurm.conf', 'r') as f:
                config = f.read()
            
            # Check if node already exists
            import re
            if node_hostname not in config:
                # Add before partition line
                config = config.replace('# PARTITION', f'{node_line}\n\n# PARTITION')
                
                # Update partition to include new node
                config = re.sub(
                    r'(PartitionName=\w+ Nodes=)([^\s]+)',
                    f'\\1\\2,{node_hostname}',
                    config
                )
                
                with open('/etc/slurm/slurm.conf', 'w') as f:
                    f.write(config)
                
                update_status(93, 'Reconfiguring cluster...', 'Updating Slurm controller')
                # Reconfigure cluster
                run_slurm_command('scontrol reconfigure')
            
            update_status(95, 'Syncing config to compute node...', 'Copying updated slurm.conf')
            
            # Copy updated slurm.conf to compute node
            sftp = ssh.open_sftp()
            sftp.put('/etc/slurm/slurm.conf', '/tmp/slurm.conf')
            sftp.close()
            
            # Move config and restart slurmd on compute node
            update_status(97, 'Restarting slurmd on compute node...', 'Applying configuration')
            stdin, stdout, stderr = ssh.exec_command(
                'echo "{}" | sudo -S cp /tmp/slurm.conf /etc/slurm/slurm.conf && '
                'echo "{}" | sudo -S systemctl restart slurmd 2>&1'.format(password, password)
            )
            stdout.read()  # Wait for completion
            
            # Verify slurmd is running
            stdin, stdout, stderr = ssh.exec_command(
                'echo "{}" | sudo -S systemctl is-active slurmd 2>/dev/null'.format(password)
            )
            status = stdout.read().decode().strip()
            
            if status == 'active':
                update_status(100, 'Deployment complete!', f'Node {node_hostname} successfully added to cluster and is now active')
                deployment_status[deploy_id]['status'] = 'completed'
            else:
                update_status(100, 'Deployment complete with warnings', f'Node {node_hostname} added but slurmd may need manual restart')
                deployment_status[deploy_id]['status'] = 'completed'
        else:
            error_output = stderr.read().decode()
            update_status(100, f'Deployment failed: {error_output[:100]}', f'Error: {error_output}')
            deployment_status[deploy_id]['status'] = 'failed'
        
        ssh.close()
        
    except Exception as e:
        update_status(100, f'Error: {str(e)}', f'Deployment failed: {str(e)}')
        deployment_status[deploy_id]['status'] = 'failed'

# ============================================================
# FLASK ROUTES
# ============================================================

@app.route('/')
def index():
    """Main dashboard."""
    stats = get_cluster_stats()
    nodes = get_nodes_detailed()
    jobs = get_jobs()
    storage = get_storage_info()
    return render_template('dashboard.html', 
                         stats=stats, 
                         nodes=nodes, 
                         jobs=jobs,
                         storage=storage,
                         page='dashboard')

@app.route('/nodes')
def nodes_page():
    """Detailed nodes view."""
    nodes = get_nodes_detailed()
    # Get GPU info for each node
    for node in nodes:
        if node.get('NodeName') == socket.gethostname():
            node['gpu_details'] = get_node_gpu_info(node['NodeName'])
    return render_template('nodes.html', nodes=nodes, page='nodes')

@app.route('/node/<node_name>')
def node_detail(node_name):
    """Single node detail view."""
    nodes = get_nodes_detailed()
    node = next((n for n in nodes if n.get('NodeName') == node_name), None)
    if node:
        node['gpu_details'] = get_node_gpu_info(node_name)
    return render_template('node_detail.html', node=node, page='nodes')

@app.route('/jobs')
def jobs_page():
    """Jobs management view."""
    jobs = get_jobs()
    return render_template('jobs.html', jobs=jobs, page='jobs')

@app.route('/storage')
def storage_page():
    """Storage and NFS view."""
    storage = get_storage_info()
    return render_template('storage.html', storage=storage, page='storage')

@app.route('/deploy')
def deploy_page():
    """Worker deployment view."""
    return render_template('deploy.html', page='deploy')

@app.route('/submit', methods=['POST'])
def submit_job():
    """Submit a new job."""
    job_script = request.form.get('job_script')
    if not job_script:
        flash('Job script cannot be empty.', 'error')
        return redirect(request.referrer or url_for('index'))

    job_script = job_script.replace('\r\n', '\n')

    try:
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.sbatch') as tmp:
            tmp.write(job_script)
            tmp_path = tmp.name
        
        output, error = run_slurm_command(f'sbatch {tmp_path}')
        os.unlink(tmp_path)

        if error:
            flash(f'Error submitting job: {error}', 'error')
        else:
            flash(f'Successfully submitted job: {output.strip()}', 'success')

    except Exception as e:
        flash(f'An unexpected error occurred: {e}', 'error')

    return redirect(request.referrer or url_for('index'))

@app.route('/cancel/<job_id>')
def cancel_job(job_id):
    """Cancel a job."""
    output, error = run_slurm_command(f'scancel {job_id}')
    if error:
        flash(f'Error canceling job {job_id}: {error}', 'error')
    else:
        flash(f'Successfully canceled job {job_id}.', 'success')
    return redirect(request.referrer or url_for('index'))

@app.route('/node/<node_name>/action/<action>')
def node_action(node_name, action):
    """Perform action on a node (drain, resume, etc)."""
    if action == 'drain':
        output, error = run_slurm_command(f'scontrol update NodeName={node_name} State=DRAIN Reason="Admin action from Web UI"')
    elif action == 'resume':
        output, error = run_slurm_command(f'scontrol update NodeName={node_name} State=RESUME')
    elif action == 'idle':
        output, error = run_slurm_command(f'scontrol update NodeName={node_name} State=IDLE')
    else:
        flash(f'Unknown action: {action}', 'error')
        return redirect(url_for('nodes_page'))
    
    if error:
        flash(f'Error performing {action} on {node_name}: {error}', 'error')
    else:
        flash(f'Successfully performed {action} on {node_name}', 'success')
    
    return redirect(url_for('nodes_page'))

@app.route('/api/deploy', methods=['POST'])
def api_deploy_worker():
    """API endpoint to start worker deployment."""
    data = request.json
    node_ip = data.get('ip')
    node_hostname = data.get('hostname')
    username = data.get('username', 'root')
    password = data.get('password')
    
    if not all([node_ip, node_hostname, password]):
        return jsonify({'error': 'Missing required fields'}), 400
    
    deploy_id = f"{node_hostname}_{int(time.time())}"
    
    # Start deployment in background thread
    thread = threading.Thread(
        target=deploy_worker_thread,
        args=(node_ip, node_hostname, username, password, deploy_id)
    )
    thread.daemon = True
    thread.start()
    
    return jsonify({'deploy_id': deploy_id, 'status': 'started'})

@app.route('/api/deploy/status/<deploy_id>')
def api_deploy_status(deploy_id):
    """Get deployment status."""
    if deploy_id in deployment_status:
        return jsonify(deployment_status[deploy_id])
    return jsonify({'error': 'Deployment not found'}), 404

@app.route('/api/stats')
def api_stats():
    """API endpoint for cluster stats (for real-time updates)."""
    return jsonify(get_cluster_stats())

@app.route('/api/terminal/exec', methods=['POST'])
def api_terminal_exec():
    """Execute a command on a node via SSH or locally."""
    data = request.json
    node_name = data.get('node')
    command = data.get('command')
    username = data.get('username', 'parallels')
    password = data.get('password')
    
    if not command:
        return jsonify({'error': 'No command provided'}), 400
    
    # Get node info to find IP
    nodes = get_nodes_detailed()
    node = next((n for n in nodes if n.get('NodeName') == node_name), None)
    
    if not node:
        return jsonify({'error': f'Node {node_name} not found'}), 404
    
    # Check if this is the local master node
    is_local = node_name == socket.gethostname()
    
    try:
        if is_local:
            # Execute locally
            output, error = run_command(command, timeout=60)
            if error:
                return jsonify({'output': '', 'error': error})
            return jsonify({'output': output or '', 'error': ''})
        else:
            # Execute via SSH
            if not password:
                return jsonify({'error': 'Password required for remote nodes'}), 400
            
            node_ip = node.get('NodeAddr') or node.get('NodeHostName') or node_name
            
            import paramiko
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(node_ip, username=username, password=password, timeout=10)
            
            # For commands that need sudo, pipe the password
            if command.strip().startswith('sudo '):
                cmd = f'echo "{password}" | sudo -S {command[5:]} 2>&1'
            else:
                cmd = command
            
            # Execute with pseudo-terminal for better compatibility
            stdin, stdout, stderr = ssh.exec_command(cmd, timeout=30, get_pty=True)
            
            # Set channel timeout to avoid hanging on interactive commands
            stdout.channel.settimeout(25)
            
            try:
                output = stdout.read().decode('utf-8', errors='replace')
            except socket.timeout:
                output = "(Command timed out - use non-interactive commands like 'top -bn1')"
            
            try:
                error = stderr.read().decode('utf-8', errors='replace')
            except:
                error = ''
            
            ssh.close()
            
            # Filter out sudo password prompt and ANSI escape codes
            output = '\n'.join([l for l in output.split('\n') if '[sudo]' not in l])
            
            return jsonify({'output': output, 'error': error})
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/nodes')
def api_nodes():
    """API endpoint for node information."""
    return jsonify(get_nodes_detailed())

@app.route('/api/jobs')
def api_jobs():
    """API endpoint for jobs."""
    return jsonify(get_jobs())

@app.route('/settings')
def settings_page():
    """Cluster settings page."""
    # Read current slurm.conf
    config_content = ""
    try:
        with open('/etc/slurm/slurm.conf', 'r') as f:
            config_content = f.read()
    except:
        pass
    
    return render_template('settings.html', config=config_content, page='settings')

@app.route('/settings/save', methods=['POST'])
def save_settings():
    """Save cluster settings."""
    config = request.form.get('config')
    if config:
        try:
            # Backup current config
            run_command('cp /etc/slurm/slurm.conf /etc/slurm/slurm.conf.backup')
            
            with open('/etc/slurm/slurm.conf', 'w') as f:
                f.write(config)
            
            # Reconfigure
            run_slurm_command('scontrol reconfigure')
            flash('Configuration saved and cluster reconfigured.', 'success')
        except Exception as e:
            flash(f'Error saving configuration: {e}', 'error')
    
    return redirect(url_for('settings_page'))

# ============================================================
# WEBSOCKET TERMINAL HANDLERS
# ============================================================

@socketio.on('connect_terminal')
def handle_terminal_connect(data):
    """Handle terminal connection via WebSocket."""
    node_name = data.get('node')
    username = data.get('username', 'parallels')
    password = data.get('password')
    sid = request.sid
    
    # Get node info
    nodes = get_nodes_detailed()
    node = next((n for n in nodes if n.get('NodeName') == node_name), None)
    
    if not node:
        emit('terminal_error', {'error': f'Node {node_name} not found'})
        return
    
    is_local = node_name == socket.gethostname()
    
    try:
        if is_local:
            # Local terminal using subprocess
            import pty
            master_fd, slave_fd = pty.openpty()
            
            process = subprocess.Popen(
                ['/bin/bash'],
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                preexec_fn=os.setsid,
                env={**os.environ, 'TERM': 'xterm-256color'}
            )
            
            ssh_sessions[sid] = {
                'type': 'local',
                'process': process,
                'master_fd': master_fd,
                'slave_fd': slave_fd
            }
            
            # Start reading thread
            def read_output():
                while sid in ssh_sessions:
                    try:
                        if select.select([master_fd], [], [], 0.1)[0]:
                            data = os.read(master_fd, 1024)
                            if data:
                                socketio.emit('terminal_output', {'data': data.decode('utf-8', errors='replace')}, room=sid)
                    except:
                        break
            
            thread = threading.Thread(target=read_output, daemon=True)
            thread.start()
            
        else:
            # Remote terminal via SSH
            if not password:
                emit('terminal_error', {'error': 'Password required'})
                return
            
            node_ip = node.get('NodeAddr') or node.get('NodeHostName') or node_name
            
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(node_ip, username=username, password=password, timeout=10)
            
            # Get interactive shell with PTY
            channel = ssh.invoke_shell(term='xterm-256color', width=120, height=40)
            channel.setblocking(0)
            
            ssh_sessions[sid] = {
                'type': 'ssh',
                'ssh': ssh,
                'channel': channel
            }
            
            # Start reading thread
            def read_ssh_output():
                while sid in ssh_sessions:
                    try:
                        if channel.recv_ready():
                            data = channel.recv(4096)
                            if data:
                                socketio.emit('terminal_output', {'data': data.decode('utf-8', errors='replace')}, room=sid)
                        else:
                            time.sleep(0.05)
                    except:
                        break
            
            thread = threading.Thread(target=read_ssh_output, daemon=True)
            thread.start()
        
        emit('terminal_connected', {'status': 'connected', 'node': node_name})
        
    except Exception as e:
        emit('terminal_error', {'error': str(e)})

@socketio.on('terminal_input')
def handle_terminal_input(data):
    """Handle input from terminal."""
    sid = request.sid
    input_data = data.get('data', '')
    
    if sid not in ssh_sessions:
        return
    
    session = ssh_sessions[sid]
    
    try:
        if session['type'] == 'local':
            os.write(session['master_fd'], input_data.encode())
        else:
            session['channel'].send(input_data)
    except Exception as e:
        emit('terminal_error', {'error': str(e)})

@socketio.on('terminal_resize')
def handle_terminal_resize(data):
    """Handle terminal resize."""
    sid = request.sid
    cols = data.get('cols', 120)
    rows = data.get('rows', 40)
    
    if sid not in ssh_sessions:
        return
    
    session = ssh_sessions[sid]
    
    try:
        if session['type'] == 'ssh':
            session['channel'].resize_pty(width=cols, height=rows)
        elif session['type'] == 'local':
            import fcntl
            import termios
            import struct
            winsize = struct.pack('HHHH', rows, cols, 0, 0)
            fcntl.ioctl(session['master_fd'], termios.TIOCSWINSZ, winsize)
    except:
        pass

@socketio.on('disconnect_terminal')
def handle_terminal_disconnect():
    """Handle terminal disconnection."""
    sid = request.sid
    cleanup_session(sid)

@socketio.on('disconnect')
def handle_disconnect():
    """Clean up on WebSocket disconnect."""
    cleanup_session(request.sid)

def cleanup_session(sid):
    """Clean up terminal session."""
    if sid in ssh_sessions:
        session = ssh_sessions[sid]
        try:
            if session['type'] == 'local':
                session['process'].terminate()
                os.close(session['master_fd'])
                os.close(session['slave_fd'])
            else:
                session['channel'].close()
                session['ssh'].close()
        except:
            pass
        del ssh_sessions[sid]

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=5000, debug=True, allow_unsafe_werkzeug=True)