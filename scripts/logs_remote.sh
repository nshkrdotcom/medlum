#!/usr/bin/env bash
# View remote server logs via SSH
# Usage: ./scripts/logs_remote.sh [target] [options]
#
# Targets (services running on luhome):
#   all       - All system logs (default)
#   lumainus  - Lumainus Phoenix app
#   docling   - Docling PDF conversion service
#   nginx     - Nginx reverse proxy
#   docker    - Docker daemon logs
#   postgres  - PostgreSQL database
#   <name>    - Any systemd service or docker container name
#
# Options:
#   -n NUM   - Number of lines to show initially (default: 100)
#   -s TIME  - Since time (default: "10 minutes ago")
#
# Examples:
#   ./scripts/logs_remote.sh                    # All logs
#   ./scripts/logs_remote.sh lumainus           # Phoenix app logs
#   ./scripts/logs_remote.sh docling            # Docling service
#   ./scripts/logs_remote.sh docling -n 500     # Docling with 500 lines
#   ./scripts/logs_remote.sh postgres           # PostgreSQL logs
#
# Environment:
#   REMOTE_SERVER - Override default server (default: luhome)

set -euo pipefail

SERVER="${REMOTE_SERVER:-luhome}"
TARGET="${1:-all}"
shift || true

# Parse options
LINES=100
SINCE="10 minutes ago"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      LINES="$2"
      shift 2
      ;;
    -s)
      SINCE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

echo "📋 Remote logs from $SERVER ($TARGET) - Ctrl+C to exit"
echo "   Since: $SINCE | Initial lines: $LINES"
echo

case "$TARGET" in
  all)
    ssh -t "$SERVER" "sudo journalctl -f -n $LINES --since '$SINCE'"
    ;;
  lumainus|phoenix|app)
    ssh -t "$SERVER" "sudo journalctl -u lumainus -f -n $LINES --since '$SINCE'"
    ;;
  docling)
    ssh -t "$SERVER" "sudo journalctl -u docling -f -n $LINES --since '$SINCE' 2>/dev/null || sudo docker logs -f --tail $LINES docling 2>/dev/null || echo 'No docling service or container found'"
    ;;
  docker)
    ssh -t "$SERVER" "sudo journalctl -u docker -f -n $LINES --since '$SINCE'"
    ;;
  nginx)
    ssh -t "$SERVER" "sudo tail -f -n $LINES /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || sudo journalctl -u nginx -f -n $LINES --since '$SINCE'"
    ;;
  postgres|postgresql)
    ssh -t "$SERVER" "sudo journalctl -u 'postgresql@*' -f -n $LINES --since '$SINCE'"
    ;;
  container|containers)
    # Show logs from all running containers
    ssh -t "$SERVER" "docker ps --format '{{.Names}}' | head -1 | xargs -I{} docker logs -f --tail $LINES {}"
    ;;
  *)
    # Assume it's a service name or container name
    ssh -t "$SERVER" "sudo journalctl -u '$TARGET' -f -n $LINES --since '$SINCE' 2>/dev/null || sudo docker logs -f --tail $LINES '$TARGET' 2>/dev/null || echo 'Service or container $TARGET not found'"
    ;;
esac
