#!/bin/bash
# cat_context_files.sh
#
# Concatenates all files referenced in docling_backend_abstraction.md
# for review by an AI agent or developer.
#
# Usage: ./cat_context_files.sh > context.txt
#        ./cat_context_files.sh | less

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

# Print separator with filename
print_file() {
    local file="$1"
    echo ""
    echo "==============================================================================="
    echo "FILE: $file"
    echo "==============================================================================="
    echo ""
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[ERROR: File not found: $file]"
    fi
    echo ""
}

echo "==============================================================================="
echo "MEDLUM DOCLING BACKEND ABSTRACTION - CONTEXT FILES"
echo "Generated: $(date)"
echo "==============================================================================="

# Core Documentation
print_file "README.md"
print_file "AGENTS.md"

# Current Implementation
print_file "lib/medlum/docling.ex"
print_file "lib/medlum/docling/queue.ex"
print_file "lib/medlum/documents/ingestion_processor.ex"

# Configuration
print_file "config/config.exs"

# Previous Design Docs
print_file "docs/20251121/VAST_AI_INTEGRATION_PLAN_refined.md"
print_file "docs/20251121/CONCURRENCY_ARCH_DOCLING.md"
print_file "docs/20251121/ingestion_queue_system_design.md"
print_file "docs/CONTINUATION_PROMPT.md"

# The design proposal itself
print_file "docs/20251123/docling_backend_abstraction.md"

# New Implementation Files
print_file "lib/medlum/docling/backend.ex"
print_file "lib/medlum/docling/http.ex"
print_file "lib/medlum/docling/backends/local.ex"
print_file "lib/medlum/docling/backends/remote.ex"
print_file "lib/medlum/docling/backends/vast_ai.ex"
print_file "lib/medlum/docling/vast_ai/instance_manager.ex"

# Test Files
print_file "test/medlum/docling/http_test.exs"
print_file "test/medlum/docling/docling_test.exs"
print_file "test/medlum/docling/backends/local_test.exs"
print_file "test/medlum/docling/backends/remote_test.exs"
print_file "test/medlum/docling/backends/vast_ai_test.exs"
print_file "test/medlum/docling/vast_ai/instance_manager_test.exs"

echo ""
echo "==============================================================================="
echo "END OF CONTEXT FILES"
echo "==============================================================================="
