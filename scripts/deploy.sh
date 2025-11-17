#!/usr/bin/env bash
# Deploy script for Lumainus
# Usage: ./scripts/deploy.sh

set -euo pipefail

SERVER="lu"
REMOTE_DIR="/var/www/lumainus"
REMOTE_USER="lumainus"
ENV_FILE=".env.prod"

run_remote() {
  local cmd="$1"
  ssh "$SERVER" "sudo -u $REMOTE_USER bash -lc 'set -euo pipefail; cd $REMOTE_DIR && $cmd'"
}

run_remote_env() {
  local cmd="$1"
  run_remote "source $ENV_FILE && MIX_ENV=\${MIX_ENV:-prod} $cmd"
}

echo "🚀 Deploying Lumainus to dev.lumainus.com..."

echo "📥 Pulling latest code..."
run_remote "git fetch origin main && git reset --hard origin/main"

echo "📦 Installing dependencies..."
run_remote_env "mix deps.get --only prod"

echo "🎨 Compiling assets..."
run_remote_env "mix assets.deploy"

echo "🗄️  Running database migrations..."
run_remote_env "mix ecto.migrate"

echo "🔄 Restarting service..."
ssh "$SERVER" "sudo systemctl restart lumainus"

echo "✅ Checking service status..."
ssh "$SERVER" "sudo systemctl status lumainus --no-pager"

echo
echo "✅ Deployment complete!"
echo "🌐 Visit: https://dev.lumainus.com"
