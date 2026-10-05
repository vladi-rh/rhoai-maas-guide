#!/usr/bin/env bash
# Delete all agent namespaces (and the agent console) from the Workload cluster.
set -euo pipefail

# shellcheck source=shared.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

WORKLOAD_CTX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./teardown-agents.sh --workload-context <ctx>"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKLOAD_CTX" ]; then
    log_error "Required: --workload-context"
    exit 1
fi

oc_w() { oc --context="$WORKLOAD_CTX" "$@"; }

echo ""
echo -e "  ${BOLD}${CYAN}━━ Deleting agent namespaces from Workload cluster${NC}"

for ns in $AGENT_NAMESPACES "$CONSOLE_NS"; do
    if oc_w get project "$ns" &>/dev/null 2>&1; then
        start_spinner "Deleting project: $ns"
        oc_w delete project "$ns" > /dev/null 2>&1 || \
        oc_w delete namespace "$ns" --wait=false > /dev/null 2>&1 || true
        stop_spinner
        log_info "Deleted: $ns"
    else
        log_info "Project $ns does not exist — skipping"
    fi
done
