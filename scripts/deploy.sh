#!/usr/bin/env bash
# Deploy script for MedLum AI
# Usage: ./scripts/deploy.sh [--refresh-runtime]

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--refresh-runtime]

  --refresh-runtime    Stop the running Phoenix service before building,
                       install prod deps, run MIX_ENV=prod mix compile,
                       then start the service again. Use this when new
                       dependencies (like SMTP adapters) are added so the
                       long-running Mix server reloads everything cleanly.
EOF
}

REFRESH_RUNTIME=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --refresh-runtime)
      REFRESH_RUNTIME=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

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
  run_remote "set -a && source $ENV_FILE && set +a && MIX_ENV=\${MIX_ENV:-prod} $cmd"
}

ensure_dir_ownership() {
  local dir="$1"
  ssh "$SERVER" "sudo bash -s" <<EOF
set -euo pipefail
cd $REMOTE_DIR
if [ -d "$dir" ]; then
  if find "$dir" ! -user $REMOTE_USER -print -quit | grep -q .; then
    echo "🔐 Fixing ownership for $dir"
    chown -R $REMOTE_USER:$REMOTE_USER "$dir"
  fi
fi
EOF
}

echo "🚀 Deploying MedLum AI to dev.medlumai.com..."

if $REFRESH_RUNTIME; then
  echo "🛑 Stopping service before build (refresh runtime)..."
  ssh "$SERVER" "sudo systemctl stop lumainus"
fi

echo "📥 Pulling latest code..."
run_remote "git fetch origin main && git reset --hard origin/main"

echo "🔐 Ensuring build/deps ownership..."
ensure_dir_ownership "_build"
ensure_dir_ownership "deps"

echo "📦 Installing dependencies..."
run_remote_env "mix deps.get --only prod"

if $REFRESH_RUNTIME; then
  echo "🛠️  Compiling application with MIX_ENV=prod..."
  run_remote_env "mix compile"
fi

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
