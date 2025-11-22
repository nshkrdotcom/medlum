# Vast.ai GPU Integration for Docling Service

## Objective
Build a complete Vast.ai integration for the Docling service that:
1. Automates instance provisioning and management via Vast.ai API
2. Establishes secure SSH tunnels for dev (automatic) and prod (manual UFW setup)
3. Handles connection monitoring, health checks, and failover
4. Provides Elixir-facing API while Python manages the infrastructure

## Context
- **Current setup**: Docling runs on `http://127.0.0.1:8042` in dev
- **Target**: Move to Vast.ai GPU rental (RTX 3090) for production Docling processing
- **Dev approach**: Automated SSH tunnel (`localhost:8042 → vast-ip:8042`)
- **Prod approach**: Manual server setup (SSH, UFW, no CI/CD yet)
- **Integration language**: Python (calls Vast.ai API, manages tunnels)
- **Consumer**: Elixir app (`config/config.exs` points to Docling base_url)

## Phase 1: Vast.ai Account & API Setup

### 1.1 Account Creation
- Sign up at vast.ai
- Add payment method (credit card or crypto)
- Generate API key from account settings
- Set spending limits ($50/month recommended for testing)

### 1.2 API Client Testing
Create `docling_service/vast_client.py`:
```python
import os
import requests

VAST_API_KEY = os.getenv("VAST_API_KEY")
BASE_URL = "https://console.vast.ai/api/v0"

def search_instances(gpu_name="RTX_3090", min_disk_gb=20):
    """Find available instances matching requirements."""
    # Implementation: GET /bundles/?q=...
    
def rent_instance(instance_id, image="vastai/pytorch"):
    """Rent a specific instance."""
    # Implementation: PUT /asks/{instance_id}/
    
def get_instance_status(instance_id):
    """Check if instance is running and get SSH details."""
    # Implementation: GET /instances/{instance_id}/
```

Test manually:
```bash
cd docling_service
export VAST_API_KEY="your-key-here"
python3 -c "from vast_client import search_instances; print(search_instances())"
```

## Phase 2: Instance Provisioning & Setup

### 2.1 Automated Instance Lifecycle
Create `docling_service/vast_manager.py`:
```python
class VastManager:
    def provision_docling_instance(self):
        """
        1. Search for RTX 3090 with >=20GB disk
        2. Rent cheapest reliable instance (reliability_score > 0.9)
        3. Wait for SSH to be ready (poll status)
        4. Return SSH connection details
        """
        
    def setup_instance(self, ssh_host, ssh_port):
        """
        Via paramiko SSH:
        1. apt-get update && apt-get install -y git
        2. git clone <your-private-docling-fork>
        3. cd docling_service && ./run.sh
        4. Wait for health check on port 8042
        """
        
    def destroy_instance(self, instance_id):
        """Clean shutdown and destroy."""
```

### 2.2 Deployment Script
Create `docling_service/setup_vast.sh`:
```bash
#!/bin/bash
# Runs on Vast.ai instance after SSH connection
set -euo pipefail

# Install deps
apt-get update
apt-get install -y git python3.11 python3.11-venv

# Clone repo (use deploy key for private repo)
mkdir -p ~/.ssh
echo "$DEPLOY_KEY" > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
git clone git@github.com:yourusername/nordic-road-docling.git

# Setup and run
cd nordic-road-docling/docling_service
./run.sh &

# Wait for health
for i in {1..30}; do
    if curl -f http://localhost:8042/health; then
        echo "Docling ready"
        exit 0
    fi
    sleep 2
done
exit 1
```

## Phase 3: SSH Tunnel Management

### 3.1 Development Tunnel (Automated)
Create `docling_service/tunnel_manager.py`:
```python
import subprocess
import time
from threading import Thread

class SSHTunnel:
    def __init__(self, remote_host, remote_port, local_port=8042, ssh_port=22):
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.local_port = local_port
        self.ssh_port = ssh_port
        self.process = None
        
    def start(self):
        """Start SSH tunnel with autossh for resilience."""
        cmd = [
            "autossh", "-M", "0", "-N",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", f"{self.local_port}:localhost:{self.remote_port}",
            "-p", str(self.ssh_port),
            f"root@{self.remote_host}"
        ]
        self.process = subprocess.Popen(cmd)
        time.sleep(2)  # Wait for tunnel
        
    def stop(self):
        if self.process:
            self.process.terminate()
            
    def health_check(self):
        """Verify tunnel is functional."""
        try:
            resp = requests.get(f"http://localhost:{self.local_port}/health", timeout=5)
            return resp.status_code == 200
        except:
            return False
```

### 3.2 Systemd Service for Dev Auto-Tunnel
Create `scripts/docling-tunnel.service`:
```ini
[Unit]
Description=Docling Vast.ai SSH Tunnel
After=network.target

[Service]
Type=simple
User=youruser
Environment="VAST_INSTANCE_ID=12345"
ExecStart=/usr/bin/python3 /path/to/docling_service/tunnel_daemon.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Create `docling_service/tunnel_daemon.py`:
```python
#!/usr/bin/env python3
"""Maintains SSH tunnel to Vast.ai instance."""
import os
import sys
import time
from vast_client import get_instance_status
from tunnel_manager import SSHTunnel

instance_id = os.getenv("VAST_INSTANCE_ID")

while True:
    status = get_instance_status(instance_id)
    if status["actual_status"] == "running":
        ssh_host = status["ssh_host"]
        ssh_port = status["ssh_port"]
        
        tunnel = SSHTunnel(ssh_host, 8042, ssh_port=ssh_port)
        tunnel.start()
        
        while tunnel.health_check():
            time.sleep(30)
            
        tunnel.stop()
    else:
        print(f"Instance {instance_id} not running, waiting...")
        time.sleep(60)
```

### 3.3 Production Setup (Manual)
**On your production server** (one-time setup):

```bash
# Install autossh
sudo apt install autossh

# Create SSH key for tunnel
ssh-keygen -t ed25519 -f ~/.ssh/vast_tunnel -N ""

# Add to Vast.ai instance's authorized_keys (via Vast web console or SSH)

# Setup persistent tunnel
cat > /etc/systemd/system/docling-tunnel.service <<EOF
[Unit]
Description=Docling Vast.ai Tunnel
After=network.target

[Service]
Type=simple
User=youruser
ExecStart=/usr/bin/autossh -M 0 -N -o "ServerAliveInterval=30" -L 8042:localhost:8042 -p VAST_SSH_PORT -i /home/youruser/.ssh/vast_tunnel root@VAST_IP
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable docling-tunnel
sudo systemctl start docling-tunnel

# Update UFW if needed
sudo ufw allow from 127.0.0.1 to any port 8042
```

## Phase 4: Elixir Integration Points

### 4.1 Config Management
Update `config/config.exs`:
```elixir
config :lumainus, :docling,
  # Dev: localhost tunnel, Prod: localhost tunnel (both use 8042)
  base_url: System.get_env("DOCLING_BASE_URL", "http://127.0.0.1:8042"),
  request_timeout: 1_200_000,
  retry_attempts: 3
```

### 4.2 Health Check GenServer
Create `lib/lumainus/docling/health_monitor.ex`:
```elixir
defmodule Lumainus.Docling.HealthMonitor do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    schedule_check()
    {:ok, %{healthy: false, last_check: nil}}
  end

  def handle_info(:check_health, state) do
    config = Application.get_env(:lumainus, :docling)
    url = "#{config[:base_url]}/health"
    
    healthy = case Req.get(url, receive_timeout: 5000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end

    if healthy != state.healthy do
      Logger.warning("Docling health changed: #{healthy}")
    end

    schedule_check()
    {:noreply, %{healthy: healthy, last_check: DateTime.utc_now()}}
  end

  defp schedule_check, do: Process.send_after(self(), :check_health, 30_000)
end
```

## Phase 5: Debugging & Testing Strategy

### 5.1 Local Testing (Before Vast.ai)
```bash
# Terminal 1: Run local Docling
cd docling_service && ./run.sh

# Terminal 2: Test from Elixir
iex -S mix phx.server
Lumainus.Docling.Queue.submit_pdf("/path/to/test.pdf")
```

### 5.2 Vast.ai Integration Testing
```bash
# Terminal 1: Provision instance
cd docling_service
export VAST_API_KEY="..."
python3 -c "from vast_manager import VastManager; VastManager().provision_docling_instance()"

# Terminal 2: Start tunnel manually
autossh -M 0 -N -L 8042:localhost:8042 -p SSH_PORT root@VAST_IP

# Terminal 3: Test Elixir integration
iex -S mix phx.server
```

### 5.3 Production Verification
```bash
# On prod server, check tunnel
systemctl status docling-tunnel
curl http://localhost:8042/health

# Check Elixir connection
ssh prod-server
cd /app && bin/lumainus remote
Lumainus.Docling.Queue.submit_pdf(...)
```

## Phase 6: Cost Management & Monitoring

### 6.1 Auto-Shutdown on Idle
Add to `vast_manager.py`:
```python
def monitor_and_shutdown_idle(instance_id, idle_minutes=30):
    """Destroy instance if no jobs for N minutes."""
    # Check Oban queue depth via HTTP or DB
    # If empty for idle_minutes, call destroy_instance()
```

### 6.2 Spending Alerts
```python
def check_daily_spend():
    """Query Vast.ai API for current month spend."""
    # GET /users/current/
    # Alert if > daily_budget
```

## Deliverables Checklist

**Python modules:**
- [ ] `vast_client.py` - API wrapper
- [ ] `vast_manager.py` - Instance lifecycle
- [ ] `tunnel_manager.py` - SSH tunnel handling
- [ ] `tunnel_daemon.py` - Dev auto-tunnel service
- [ ] `setup_vast.sh` - Instance bootstrap script

**Elixir integration:**
- [ ] `HealthMonitor` GenServer
- [ ] Config updates for DOCLING_BASE_URL
- [ ] Add HealthMonitor to application.ex supervision tree

**Deployment artifacts:**
- [ ] `docling-tunnel.service` systemd unit
- [ ] Production UFW setup script
- [ ] Deploy key setup instructions

**Documentation:**
- [ ] `docs/vast_ai_setup.md` - Initial account/API setup
- [ ] `docs/vast_ai_dev.md` - Development workflow with tunnels
- [ ] `docs/vast_ai_prod.md` - Production manual setup guide
- [ ] Cost monitoring runbook

## Testing Milestones

1. **M1**: Vast.ai API working (search + rent instance)
2. **M2**: Instance provisions and runs Docling
3. **M3**: SSH tunnel connects and health check passes
4. **M4**: Elixir successfully submits PDF via tunnel
5. **M5**: Tunnel auto-recovers from network blip
6. **M6**: Production tunnel stable for 24h+
7. **M7**: Cost monitoring alerts working
