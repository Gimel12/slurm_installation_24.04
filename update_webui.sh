#!/bin/bash
# Simple script to update the Slurm Web UI from GitHub
# Run this on the master node after pushing changes

echo "=== Updating Slurm Web UI ==="

cd /home/bizon/slurm_installation_24.04

echo "Pulling latest changes..."
git pull origin main

echo "Restarting Web UI..."
pkill -f 'python.*app.py' 2>/dev/null
sleep 1

cd slurm_web_ui
nohup python3 app.py --host 0.0.0.0 --port 5000 > /tmp/webui.log 2>&1 &

sleep 2
if pgrep -f 'python.*app.py' > /dev/null; then
    echo "✅ Web UI updated and running!"
    echo "   Access at: http://172.30.1.205:5000"
else
    echo "❌ Failed to start. Check /tmp/webui.log"
fi
