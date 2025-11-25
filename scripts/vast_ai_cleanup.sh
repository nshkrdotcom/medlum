#!/bin/bash
# Vast.ai Auto-Shutdown Script
# =============================
# Checks for idle GPU instances and destroys them to save money.
#
# Usage:
#   ./scripts/vast_ai_cleanup.sh              # Normal check
#   ./scripts/vast_ai_cleanup.sh --dry-run    # Check without destroying
#   ./scripts/vast_ai_cleanup.sh --timeout 30 # Override idle timeout
#
# Crontab example (run every 5 minutes):
#   */5 * * * * cd /path/to/lumainus && ./scripts/vast_ai_cleanup.sh >> /var/log/vast_ai_cleanup.log 2>&1
#
# For production releases:
#   */5 * * * * cd /app && bin/lumainus eval "Lumainus.Docling.VastAI.AutoShutdown.check_and_shutdown()"

set -e
cd "$(dirname "$0")/.."

# Check if running in a release or dev environment
if [ -f "bin/lumainus" ]; then
    # Production release
    exec bin/lumainus eval "
      case Lumainus.Docling.VastAI.AutoShutdown.check_and_shutdown() do
        {:ok, :no_instances} -> IO.puts(\"No instances running\")
        {:ok, :still_active} -> IO.puts(\"Instance active, keeping alive\")
        {:ok, :destroyed, id} -> IO.puts(\"Destroyed idle instance #\#{id}\")
        {:error, reason} -> IO.puts(\"Error: \#{inspect(reason)}\"); System.halt(1)
      end
    "
else
    # Development with Mix
    if command -v mix &> /dev/null; then
        exec mix vast_ai.cleanup "$@"
    else
        echo "Error: Neither release binary nor mix found"
        exit 1
    fi
fi
