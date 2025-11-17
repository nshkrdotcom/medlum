#!/usr/bin/env bash
# Initial server setup script for Lumainus
# Run this ONCE on the server to set everything up
# Usage: ssh lu 'bash -s' < scripts/server_setup.sh

set -euo pipefail

APP_NAME="lumainus"
APP_DIR="/var/www/lumainus"
APP_USER="lumainus"
REPO_URL="git@github.com:nshkrdotcom/lumainus.git"  # Update with your repo
DB_NAME="${APP_NAME}_prod"
DB_PASS="changeme"
ENV_FILE="$APP_DIR/.env.prod"

run_as_app() {
  sudo -u "$APP_USER" bash -lc "set -euo pipefail; $1"
}

run_in_app_dir() {
  run_as_app "cd $APP_DIR && $1"
}

run_in_app_dir_with_env() {
  run_in_app_dir "source $ENV_FILE && MIX_ENV=\${MIX_ENV:-prod} $1"
}

echo "🔧 Setting up $APP_NAME server..."

# Create app user if doesn't exist
if ! id "$APP_USER" &>/dev/null; then
  echo "👤 Creating user $APP_USER..."
  sudo useradd -m -s /bin/bash "$APP_USER"
fi

# Create app directory
echo "📁 Creating app directory..."
sudo mkdir -p "$APP_DIR"
sudo chown "$APP_USER:$APP_USER" "$APP_DIR"

# Clone repo (or pull if exists)
if [ ! -d "$APP_DIR/.git" ]; then
  echo "📥 Cloning repository..."
  run_as_app "git clone $REPO_URL $APP_DIR"
else
  echo "📥 Repository exists, pulling latest..."
  run_in_app_dir "git fetch origin main && git reset --hard origin/main"
fi

# Install PostgreSQL if not installed
if ! command -v psql &>/dev/null; then
  echo "🗄️  Installing PostgreSQL..."
  sudo apt-get update
  sudo apt-get install -y postgresql postgresql-contrib
fi

# Create database and user
echo "🗄️  Setting up database..."
sudo -u postgres psql -c "CREATE USER $APP_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $APP_USER;" 2>/dev/null || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $APP_USER;" 2>/dev/null || true

# Install postfix for local SMTP
if ! command -v postfix &>/dev/null; then
  echo "📧 Installing Postfix..."
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
fi

# Create environment file
echo "⚙️  Creating environment file..."
if ! SECRET_KEY_BASE=$(run_in_app_dir "mix phx.gen.secret" 2>/dev/null); then
  SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
fi
sudo tee "$ENV_FILE" >/dev/null <<EOF
# Lumainus Production Environment
MIX_ENV=prod
PHX_SERVER=true
PHX_HOST=dev.lumainus.com
PORT=4000

# Secret key base
SECRET_KEY_BASE=$SECRET_KEY_BASE

# Database
DATABASE_URL=ecto://$APP_USER:$DB_PASS@localhost/$DB_NAME
POOL_SIZE=10

# SMTP (local server)
SMTP_RELAY=localhost
SMTP_PORT=25

# Optional: Set these if you need SMTP auth
# SMTP_USERNAME=
# SMTP_PASSWORD=
EOF

sudo chown "$APP_USER:$APP_USER" "$ENV_FILE"
sudo chmod 600 "$ENV_FILE"

# Install dependencies
echo "📦 Installing dependencies..."
run_in_app_dir_with_env "mix deps.get --only prod"

# Compile assets
echo "🎨 Compiling assets..."
run_in_app_dir_with_env "mix assets.deploy"

# Run migrations
echo "🗄️  Running migrations..."
run_in_app_dir_with_env "mix ecto.create && mix ecto.migrate"

# Create systemd service
echo "🔧 Creating systemd service..."
sudo tee /etc/systemd/system/lumainus.service >/dev/null <<EOF
[Unit]
Description=Lumainus Phoenix Application
After=network.target postgresql.service

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env.prod
ExecStart=/usr/bin/mix phx.server
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=lumainus

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable service
echo "🔄 Enabling service..."
sudo systemctl daemon-reload
sudo systemctl enable lumainus
sudo systemctl restart lumainus

echo
echo "✅ Server setup complete!"
echo
echo "Next steps:"
echo "1. Update $ENV_FILE with your secure secrets"
echo "2. Run: sudo systemctl restart lumainus"
echo "3. Check logs: sudo journalctl -u lumainus -f"
echo "4. Configure nginx/caddy reverse proxy for HTTPS"
