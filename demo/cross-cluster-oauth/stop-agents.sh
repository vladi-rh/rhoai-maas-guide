#!/usr/bin/env bash
# Stop all agent deployments by scaling to 0.
# Usage: ./stop-agents.sh --workload-context <ctx>
set -euo pipefail

# shellcheck source=shared.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

WORKLOAD_CTX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./stop-agents.sh --workload-context <ctx>"
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

NAMESPACES=(agents-chatbots agents-code-reviewers agents-business-analysts)

echo ""
echo -e "  ${BOLD}${CYAN}━━ Stopping agents${NC}"

for ns in "${NAMESPACES[@]}"; do
    oc_w scale deployment -l demo=cross-cluster-oauth -n "$ns" --replicas=0 > /dev/null
    log_info "Stopped: $ns"
done

echo ""
log_info "All agent deployments scaled to 0."
