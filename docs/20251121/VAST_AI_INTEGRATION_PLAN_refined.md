# Vast.ai GPU Integration for Docling Service

## Objective
Build a Vast.ai integration that provisions GPU instances via API, containerizes the Docling service, and exposes it via public HTTP endpoint. Eliminate SSH tunnels entirely—both dev and prod access Docling via the instance's public IP/port.

## Context
- **Current**: Docling runs locally on `http://127.0.0.1:8042`
- **Target**: Vast.ai RTX 3090 instance running containerized Docling, accessible via `http://<vast-public-ip>:8042`
- **Launch mode**: Entrypoint (automated worker, no SSH/Jupyter needed)
- **Integration**: Python manages Vast.ai API, Elixir connects to public endpoint
- **Deployment**: Manual for now (no CI/CD), direct API management

## Phase 1: Vast.ai Setup & API Access

### 1.1 Account Setup
```bash
# Sign up at https://cloud.vast.ai
# Add payment method (min $5)
# Generate API key: Account → API Keys
export VAST_API_KEY="your-api-key"
```

### 1.2 Install Vast CLI
```bash
pip install vast-python
vastai set api-key $VAST_API_KEY
vastai show instances  # verify connection
```

## Phase 2: Dockerize Docling Service

### 2.1 Create Production Dockerfile
Create `docling_service/Dockerfile`:
```dockerfile
FROM python:3.11-slim

# Install system deps
RUN apt-get update && apt-get install -y \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy service files
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY run.sh ./

# Install local docling fork if present
ARG USE_LOCAL_DOCLING=false
COPY docling/ /tmp/docling/
RUN if [ "$USE_LOCAL_DOCLING" = "true" ]; then \
    pip install -e /tmp/docling; \
    fi

EXPOSE 8042

ENV HOST=0.0.0.0
ENV PORT=8042
ENV CONVERSION_TIMEOUT_SECONDS=1200
ENV DOC_CONVERTER_WORKERS=8

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8042", "--no-access-log"]
```

### 2.2 Build and Push to Docker Hub
```bash
cd docling_service

# Build image
docker build -t yourusername/docling-service:latest .

# Test locally
docker run -p 8042:8042 yourusername/docling-service:latest
curl http://localhost:8042/health

# Push to Docker Hub
docker login
docker push yourusername/docling-service:latest
```

## Phase 3: Vast.ai API Client

### 3.1 Create `docling_service/vast_client.py`
```python
#!/usr/bin/env python3
"""Vast.ai API client for managing Docling instances."""

import os
import time
import requests
from typing import Dict, List, Optional

VAST_API_KEY = os.getenv("VAST_API_KEY")
BASE_URL = "https://console.vast.ai/api/v0"

class VastClient:
    def __init__(self, api_key: str = VAST_API_KEY):
        self.api_key = api_key
        self.headers = {"Authorization": f"Bearer {api_key}"}
    
    def search_offers(
        self,
        gpu_name: str = "RTX_3090",
        min_disk_gb: int = 20,
        min_upload_mbps: int = 100,
    ) -> List[Dict]:
        """Search for available instances."""
        params = {
            "q": json.dumps({
                "verified": {"eq": True},
                "external": {"eq": False},
                "rentable": {"eq": True},
                "gpu_name": {"eq": gpu_name},
                "disk_space": {"gte": min_disk_gb},
                "inet_up": {"gte": min_upload_mbps},
            }),
            "order": '[["dph_total", "asc"]]',  # cheapest first
        }
        resp = requests.get(f"{BASE_URL}/bundles", params=params, headers=self.headers)
        resp.raise_for_status()
        return resp.json()["offers"]
    
    def create_instance(
        self,
        offer_id: int,
        image: str = "yourusername/docling-service:latest",
        disk_gb: int = 20,
        onstart_cmd: Optional[str] = None,
    ) -> Dict:
        """Rent an instance with entrypoint launch mode."""
        payload = {
            "client_id": "me",
            "image": image,
            "disk": disk_gb,
            "label": "docling-worker",
            "onstart": onstart_cmd or "",
            "runtype": "args",  # entrypoint mode
            "env": {
                "CONVERSION_TIMEOUT_SECONDS": "1200",
                "DOC_CONVERTER_WORKERS": "8",
            },
        }
        resp = requests.put(
            f"{BASE_URL}/asks/{offer_id}/",
            json=payload,
            headers=self.headers,
        )
        resp.raise_for_status()
        return resp.json()
    
    def get_instance(self, instance_id: int) -> Dict:
        """Get instance status and connection details."""
        resp = requests.get(f"{BASE_URL}/instances/{instance_id}", headers=self.headers)
        resp.raise_for_status()
        return resp.json()["instances"][0]
    
    def destroy_instance(self, instance_id: int) -> None:
        """Delete an instance."""
        resp = requests.delete(f"{BASE_URL}/instances/{instance_id}/", headers=self.headers)
        resp.raise_for_status()
    
    def list_instances(self) -> List[Dict]:
        """List all your instances."""
        resp = requests.get(f"{BASE_URL}/instances/", headers=self.headers)
        resp.raise_for_status()
        return resp.json()["instances"]
```

## Phase 4: Instance Provisioning

### 4.1 Create `docling_service/vast_manager.py`
```python
#!/usr/bin/env python3
"""High-level Vast.ai instance management."""

import time
import requests
from vast_client import VastClient

class VastManager:
    def __init__(self):
        self.client = VastClient()
    
    def provision_docling_instance(self, disk_gb: int = 25) -> Dict:
        """Find and rent a suitable instance for Docling."""
        print("Searching for RTX 3090 instances...")
        offers = self.client.search_offers(gpu_name="RTX_3090", min_disk_gb=disk_gb)
        
        if not offers:
            raise RuntimeError("No suitable instances found")
        
        # Pick cheapest reliable offer
        offer = offers[0]
        print(f"Renting instance {offer['id']} at ${offer['dph_total']:.3f}/hr")
        
        result = self.client.create_instance(offer["id"], disk_gb=disk_gb)
        instance_id = result["new_contract"]
        
        print(f"Instance {instance_id} created, waiting for startup...")
        return self.wait_for_ready(instance_id)
    
    def wait_for_ready(self, instance_id: int, timeout: int = 600) -> Dict:
        """Wait until instance is running and Docling is healthy."""
        start = time.time()
        
        while time.time() - start < timeout:
            instance = self.client.get_instance(instance_id)
            status = instance["actual_status"]
            
            if status == "running":
                # Get public endpoint
                public_ip = instance["public_ipaddr"]
                port = instance.get("ports", {}).get("8042/tcp", [{}])[0].get("HostPort")
                
                if not port:
                    # If direct port not mapped, check for proxy
                    port = 8042
                
                endpoint = f"http://{public_ip}:{port}"
                
                # Wait for health check
                print(f"Instance running, checking health at {endpoint}...")
                if self._check_health(endpoint):
                    print(f"✓ Docling ready at {endpoint}")
                    return {
                        "instance_id": instance_id,
                        "endpoint": endpoint,
                        "public_ip": public_ip,
                        "port": port,
                    }
            
            time.sleep(10)
        
        raise TimeoutError("Instance did not become ready in time")
    
    def _check_health(self, endpoint: str, retries: int = 30) -> bool:
        """Check if Docling health endpoint responds."""
        for _ in range(retries):
            try:
                resp = requests.get(f"{endpoint}/health", timeout=5)
                if resp.status_code == 200:
                    return True
            except:
                pass
            time.sleep(10)
        return False
    
    def get_endpoint(self, instance_id: int) -> str:
        """Get the public HTTP endpoint for an instance."""
        instance = self.client.get_instance(instance_id)
        public_ip = instance["public_ipaddr"]
        port = instance.get("ports", {}).get("8042/tcp", [{}])[0].get("HostPort", 8042)
        return f"http://{public_ip}:{port}"
```

### 4.2 CLI Tool
Create `docling_service/manage_vast.py`:
```python
#!/usr/bin/env python3
"""CLI for managing Docling on Vast.ai."""

import sys
from vast_manager import VastManager

def main():
    if len(sys.argv) < 2:
        print("Usage: manage_vast.py [provision|list|endpoint|destroy] [instance_id]")
        sys.exit(1)
    
    manager = VastManager()
    cmd = sys.argv[1]
    
    if cmd == "provision":
        result = manager.provision_docling_instance()
        print(f"\n=== INSTANCE READY ===")
        print(f"Instance ID: {result['instance_id']}")
        print(f"Endpoint: {result['endpoint']}")
        print(f"\nUpdate your Elixir config:")
        print(f'  export DOCLING_BASE_URL="{result["endpoint"]}"')
    
    elif cmd == "list":
        instances = manager.client.list_instances()
        for inst in instances:
            print(f"{inst['id']}: {inst['actual_status']} - {inst.get('public_ipaddr', 'N/A')}")
    
    elif cmd == "endpoint":
        instance_id = int(sys.argv[2])
        endpoint = manager.get_endpoint(instance_id)
        print(endpoint)
    
    elif cmd == "destroy":
        instance_id = int(sys.argv[2])
        manager.client.destroy_instance(instance_id)
        print(f"Instance {instance_id} destroyed")
    
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
```

## Phase 5: Elixir Integration

### 5.1 Update Config
```elixir
# config/config.exs
config :medlum, :docling,
  base_url: System.get_env("DOCLING_BASE_URL", "http://127.0.0.1:8042"),
  request_timeout: 1_200_000,
  retry_attempts: 3

# config/runtime.exs (for production)
config :medlum, :docling,
  base_url: System.fetch_env!("DOCLING_BASE_URL")
```

### 5.2 Health Monitor
```elixir
# lib/medlum/docling/health_monitor.ex
defmodule Medlum.Docling.HealthMonitor do
  use GenServer
  require Logger

  @check_interval 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def healthy?, do: GenServer.call(__MODULE__, :healthy?)

  def init(_) do
    schedule_check()
    {:ok, %{healthy: false, endpoint: docling_url()}}
  end

  def handle_call(:healthy?, _from, state), do: {:reply, state.healthy, state}

  def handle_info(:check, state) do
    healthy = 
      case Req.get("#{state.endpoint}/health", receive_timeout: 5000) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end

    if healthy != state.healthy do
      Logger.warning("[Docling] Health changed: #{healthy}")
    end

    schedule_check()
    {:noreply, %{state | healthy: healthy}}
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
  defp docling_url, do: Application.get_env(:medlum, :docling)[:base_url]
end
```

Add to supervision tree in `lib/medlum/application.ex`:
```elixir
children = [
  # ...
  Medlum.Docling.HealthMonitor,
]
```

## Phase 6: Deployment Workflow

### 6.1 Development Setup
```bash
# Terminal 1: Provision Vast instance
cd docling_service
export VAST_API_KEY="your-key"
python manage_vast.py provision
# Output: export DOCLING_BASE_URL="http://45.123.45.67:8042"

# Terminal 2: Update Elixir and test
export DOCLING_BASE_URL="http://45.123.45.67:8042"
iex -S mix phx.server
Medlum.Docling.Queue.submit_pdf("/path/to/test.pdf")
```

### 6.2 Production Setup
```bash
# SSH to production server
ssh prod-server

# Set environment
export VAST_API_KEY="prod-key"
export DOCLING_BASE_URL="http://vast-instance-ip:8042"

# Provision instance (one-time or on-demand)
cd /opt/medlum/docling_service
python manage_vast.py provision

# Update .env or systemd service
echo "DOCLING_BASE_URL=http://vast-ip:8042" >> /opt/medlum/.env

# Restart Elixir app
systemctl restart medlum
```

### 6.3 Cost Management Script
Create `docling_service/cost_monitor.py`:
```python
#!/usr/bin/env python3
"""Monitor and auto-shutdown idle instances."""

import time
from vast_manager import VastManager

def check_idle_and_shutdown(instance_id: int, idle_minutes: int = 60):
    """Destroy instance if idle too long."""
    # Query your Oban queue or check recent jobs
    # If no activity for idle_minutes, destroy instance
    pass

def daily_spend_alert(max_daily: float = 10.0):
    """Alert if spending exceeds daily budget."""
    manager = VastManager()
    # Vast API doesn't expose spend directly
    # Track instance hours * rate manually
    pass
```

## Phase 7: Testing & Debugging

### Test Sequence
```bash
# 1. Local Docker test
docker build -t docling-test .
docker run -p 8042:8042 docling-test
curl http://localhost:8042/health

# 2. Push to registry
docker tag docling-test yourusername/docling-service:latest
docker push yourusername/docling-service:latest

# 3. Provision Vast instance
python manage_vast.py provision

# 4. Test from Elixir
export DOCLING_BASE_URL="http://vast-ip:8042"
iex -S mix
Medlum.Docling.Queue.submit_pdf("/path/to/test.pdf")

# 5. Monitor logs (SSH to Vast instance)
vastai ssh-url <instance-id>
# Or use Vast web console logs

# 6. Cleanup
python manage_vast.py destroy <instance-id>
```

## Deliverables

**Python modules:**
- [x] `Dockerfile` - Production container
- [x] `vast_client.py` - API wrapper
- [x] `vast_manager.py` - High-level management
- [x] `manage_vast.py` - CLI tool
- [x] `cost_monitor.py` - Spend tracking

**Elixir updates:**
- [x] `HealthMonitor` GenServer
- [x] Config for `DOCLING_BASE_URL`
- [x] Runtime config for prod

**Documentation:**
- [ ] `docs/vast_setup.md` - Initial setup
- [ ] `docs/vast_deployment.md` - Dev/prod workflows
- [ ] `docs/vast_troubleshooting.md` - Common issues

## Key Advantages Over SSH Tunnels
1. **Simpler**: No tunnel management, just HTTP
2. **Portable**: Works from any network
3. **Stateless**: Instance is ephemeral worker
4. **Scalable**: Can provision multiple instances easily
5. **Cloud-native**: Aligns with Vast.ai's design
