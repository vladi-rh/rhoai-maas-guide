#!/usr/bin/env bash
# Start agent deployments and tail color-coded logs.
# Usage: ./start-agents.sh --workload-context <ctx> [--cycles N]
#   --cycles N  each agent repeats its profile pattern N times (default: 0 = run forever)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

WORKLOAD_CTX=""
CYCLES=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        --cycles)           CYCLES="$2";       shift 2 ;;
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

oc_w() { oc --context="$WORKLOAD_CTX" "$@"; }

NAMESPACES=(agents-chatbots agents-code-reviewers agents-business-analysts)

echo ""
echo -e "  ${BOLD}${CYAN}━━ Starting agents${NC}"
if [ "$CYCLES" -gt 0 ]; then
    log_info "Each agent will run ${BOLD}${CYCLES}${NC} cycle(s) then stop"
else
    log_info "Agents will run until stopped (no cycle limit)"
fi

for ns in "${NAMESPACES[@]}"; do
    oc_w set env deployment -l demo=cross-cluster-oauth -n "$ns" "MAX_CYCLES=${CYCLES}" > /dev/null
    oc_w scale deployment -l demo=cross-cluster-oauth -n "$ns" --replicas=1 > /dev/null
    log_info "Started: $ns"
done

echo ""

# Dracula colors per agent type
C_CHATBOT="$D_CYAN"
C_REVIEWER="$D_GREEN"
C_ANALYST="$D_PURPLE"

declare -A AGENT_COLOR=(
    [chatbot-1]="$C_CHATBOT"
    [chatbot-2]="$C_CHATBOT"
    [reviewer-1]="$C_REVIEWER"
    [reviewer-2]="$C_REVIEWER"
    [analyst-1]="$C_ANALYST"
)
declare -A AGENT_NS=(
    [chatbot-1]=agents-chatbots
    [chatbot-2]=agents-chatbots
    [reviewer-1]=agents-code-reviewers
    [reviewer-2]=agents-code-reviewers
    [analyst-1]=agents-business-analysts
)

echo -e "  ${BOLD}Tailing agent logs (Ctrl-C to stop watching):${NC}"
echo -e "  ${C_CHATBOT}■${NC} chatbots   ${C_REVIEWER}■${NC} code-reviewers   ${C_ANALYST}■${NC} business-analysts"
echo ""

# Wait for all agent pods to be Running before attaching log tails
start_spinner "Waiting for agent pods to start..."
for agent_id in chatbot-1 chatbot-2 reviewer-1 reviewer-2 analyst-1; do
    ns="${AGENT_NS[$agent_id]}"
    for i in $(seq 1 30); do
        PHASE=$(oc_w get pods -n "$ns" -l "agent-id=${agent_id}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        [ "$PHASE" = "Running" ] && break
        sleep 2
    done
done
stop_spinner
echo ""

DONE_DIR=$(mktemp -d)
TOTAL_AGENTS=5
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$DONE_DIR"; echo ""; log_info "Log tailing stopped."' INT TERM EXIT

for agent_id in chatbot-1 chatbot-2 reviewer-1 reviewer-2 analyst-1; do
    ns="${AGENT_NS[$agent_id]}"
    color="${AGENT_COLOR[$agent_id]}"
    (
        oc_w logs -f deployment/"$agent_id" -n "$ns" 2>/dev/null | while IFS= read -r line; do
            printf "${color}[%-10s]${NC} %s\n" "$agent_id" "$line"
            # Mark this agent as done when it logs the idle message
            if echo "$line" | grep -q "done — idling"; then
                touch "$DONE_DIR/$agent_id"
            fi
        done
    ) &
done

# Monitor for all agents done — check every 3s
while true; do
    sleep 3
    DONE_COUNT=$(ls "$DONE_DIR" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DONE_COUNT" -ge "$TOTAL_AGENTS" ]; then
        kill $(jobs -p) 2>/dev/null || true
        echo ""
        printf "  ${D_PINK}All agents completed their cycles.${NC} Stop agents? [y/N]: "
        read -r ANS
        case "$ANS" in
            [yY]|[yY][eE][sS])
                echo ""
                "${DIR}/stop-agents.sh" --workload-context "$WORKLOAD_CTX"
                ;;
        esac
        break
    fi
done
