#!/usr/bin/env bash
# Start Medlum's native Docling service on a configured GPU host.
set -euo pipefail

target="${1:?Usage: bootstrap_vast_gpu.sh user@host[:port] [branch]}"
branch="${2:-main}"
repo_url="${REPO_URL:-https://github.com/nshkrdotcom/medlum.git}"
remote_root="${REMOTE_ROOT:-/opt/medlum}"
port="${PORT:-8044}"
host="${HOST:-0.0.0.0}"
torch_index="${DOCLING_TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
ssh_options=()
if [[ "$target" =~ ^([^:]+):([0-9]+)$ ]]; then
    target="${BASH_REMATCH[1]}"
    ssh_options=(-p "${BASH_REMATCH[2]}")
fi

printf -v remote_command 'bash -s -- %q %q %q %q %q %q' \
    "$repo_url" "$remote_root" "$branch" "$port" "$host" "$torch_index"
ssh "${ssh_options[@]}" -- "$target" "$remote_command" <<'REMOTE'
set -euo pipefail
repo_url="$1"
remote_root="$2"
branch="$3"
export PORT="$4" HOST="$5" DOCLING_TORCH_INDEX="$6"
export DEBIAN_FRONTEND=noninteractive
sudo_command=()
if (( EUID != 0 )); then
    sudo_command=(sudo)
fi
"${sudo_command[@]}" apt-get update
"${sudo_command[@]}" apt-get install -y --no-install-recommends \
    git python3-venv libgl1 libglib2.0-0
mkdir -p "$remote_root"
cd "$remote_root"
if [[ ! -d medlum/.git ]]; then
    git clone --branch "$branch" "$repo_url" medlum
else
    git -C medlum switch "$branch"
    git -C medlum pull --ff-only origin "$branch"
fi

cd medlum/docling_service
export DOCLING_VENV_DIR="$PWD/.venv-gpu"
nohup ./run.sh > "$remote_root/docling_service.log" 2>&1 </dev/null &
printf 'Docling launch started. Logs: %s/docling_service.log\n' "$remote_root"
REMOTE
