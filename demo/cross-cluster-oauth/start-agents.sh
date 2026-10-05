#!/usr/bin/env bash
# Start agent traffic via the agent console API.
#
# The pods are always running and idle; this flips their start signal, so all
# agents begin at the same moment with no pod restart and no token re-mint.
#
# Usage: ./start-agents.sh --workload-context <ctx> [--agent <id>]... [--reset]
#   --agent ID  start only this agent (repeatable; default: all)
#   --reset     zero the counters before starting
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
BODY="{\"reset\": ${RESET}}"

echo ""
echo -e "  ${BOLD}${CYAN}━━ Starting agents${NC}"
log_info "Agents repeat their profile pattern until stopped"
log_detail "Console: ${CONSOLE_URL}"
echo ""

if [ -n "$SELECTED" ]; then
    for agent_id in $SELECTED; do
        console_api "$CONSOLE_URL" "/api/agents/${agent_id}/start" POST "$BODY" > /dev/null
        log_info "Started: ${agent_id}"
    done
    console_api "$CONSOLE_URL" "/api/status" | render_agent_status
else
    console_api "$CONSOLE_URL" "/api/start" POST "$BODY" | render_agent_status
fi

echo ""
echo "  Watch live:    ${CONSOLE_URL}"
echo "  Tail logs:     ./follow-agents.sh --workload-context ${WORKLOAD_CTX}"
echo "  Stop:          ./stop-agents.sh --workload-context ${WORKLOAD_CTX}"
echo ""
