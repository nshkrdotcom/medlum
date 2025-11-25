#!/bin/bash
# Vast.ai onstart script to set up Caddy reverse proxy with automatic HTTPS
# This runs on the host (not inside the container) when the instance starts
#
# Environment variables (set by VastAI provisioning):
#   CADDY_DOMAIN - Domain for HTTPS cert (e.g., docling.lumainus.com)
#   BACKEND_PORT - Port where Docling container is running (default: 8044)

set -e

DOMAIN="${CADDY_DOMAIN:-docling.lumainus.com}"
BACKEND_PORT="${BACKEND_PORT:-8044}"
LOG="/var/log/caddy-setup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "Starting Caddy setup for $DOMAIN -> localhost:$BACKEND_PORT"

# Install Caddy
log "Installing Caddy..."
apt-get update -y
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

apt-get update -y
apt-get install -y caddy

# Create Caddyfile
log "Creating Caddyfile..."
cat > /etc/caddy/Caddyfile << EOF
# Automatic HTTPS reverse proxy for Docling service
$DOMAIN {
    reverse_proxy localhost:$BACKEND_PORT

    # Health check endpoint passthrough
    handle /health {
        reverse_proxy localhost:$BACKEND_PORT
    }

    # Logging
    log {
        output file /var/log/caddy/access.log
        format json
    }
}
EOF

# Create log directory
mkdir -p /var/log/caddy

# Wait for backend to be available (container might still be starting)
log "Waiting for backend on port $BACKEND_PORT..."
for i in {1..60}; do
  if curl -s "http://localhost:$BACKEND_PORT/health" > /dev/null 2>&1; then
    log "Backend is ready!"
    break
  fi
  log "Waiting for backend... ($i/60)"
  sleep 5
done

# Start Caddy
log "Starting Caddy..."
systemctl enable caddy
systemctl restart caddy

# Wait for certificate
log "Waiting for HTTPS certificate (this may take a minute)..."
for i in {1..30}; do
  if curl -s "https://$DOMAIN/health" > /dev/null 2>&1; then
    log "HTTPS is working!"
    break
  fi
  log "Waiting for certificate... ($i/30)"
  sleep 10
done

log "Caddy setup complete. Service available at https://$DOMAIN"
