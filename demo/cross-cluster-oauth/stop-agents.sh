#!/usr/bin/env bash
# Stop agent traffic via the agent console API.
#
# Pods stay running and idle, so counters survive and a restart is instant.
# To remove the pods entirely, use teardown-agents.sh.
#
# Usage: ./stop-agents.sh --workload-context <ctx> [--agent <id>]... [--reset]
#   --agent ID  stop only this agent (repeatable; default: all)
#   --reset     also zero the counters
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

WORKLOAD_CTX=""
RESET=false
SELECTED=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        --agent)            SELECTED="${SELECTED} $2"; shift 2 ;;
        --reset)            RESET=true;        shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKLOAD_CTX" ]; then
    log_error "Required: --workload-context"
    exit 1
fi

CONSOLE_URL=$(require_console "$WORKLOAD_CTX") || exit 1

echo ""
echo -e "  ${BOLD}${CYAN}━━ Stopping agents${NC}"
echo ""

if [ -n "$SELECTED" ]; then
    for agent_id in $SELECTED; do
        console_api "$CONSOLE_URL" "/api/agents/${agent_id}/stop" POST '{}' > /dev/null
        log_info "Stopped: ${agent_id}"
    done
else
    console_api "$CONSOLE_URL" "/api/stop" POST '{}' > /dev/null
    log_info "All agents stopped"
fi

if [ "$RESET" = true ]; then
    if [ -n "$SELECTED" ]; then
        for agent_id in $SELECTED; do
            console_api "$CONSOLE_URL" "/api/agents/${agent_id}/reset" POST '{}' > /dev/null
        done
    else
        console_api "$CONSOLE_URL" "/api/reset" POST '{}' > /dev/null
    fi
    log_info "Counters reset"
fi

echo ""
console_api "$CONSOLE_URL" "/api/status" | render_agent_status
echo ""
