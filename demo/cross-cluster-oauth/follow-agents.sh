#!/usr/bin/env bash
# Tail all agent logs, colour-coded per agent group.
#
# Read-only: this does not start or stop anything. Use the agent console, or
# start-agents.sh / stop-agents.sh, to control traffic.
#
# Usage: ./follow-agents.sh --workload-context <ctx> [--agent <id>]...
#   --agent <id>  follow only these agents (repeatable; default: all)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

WORKLOAD_CTX=""
SELECTED=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        --agent)            SELECTED="${SELECTED} $2"; shift 2 ;;
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

FOLLOW="${SELECTED:-$AGENT_IDS}"

echo ""
echo -e "  ${BOLD}${CYAN}━━ Following agent logs${NC} ${DIM}(Ctrl-C to stop watching)${NC}"
echo -e "  ${D_CYAN}■${NC} chatbots   ${D_GREEN}■${NC} code-reviewers   ${D_PURPLE}■${NC} business-analysts"
echo ""

# Wait for the pods to exist before attaching tails
start_spinner "Waiting for agent pods..."
for agent_id in $FOLLOW; do
    ns=$(agent_ns "$agent_id")
    for _ in $(seq 1 30); do
        PHASE=$(oc_w get pods -n "$ns" -l "agent-id=${agent_id}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        [ "$PHASE" = "Running" ] && break
        sleep 2
    done
done
stop_spinner
echo ""

DONE_DIR=$(mktemp -d)
TOTAL=$(echo "$FOLLOW" | wc -w | tr -d ' ')
# shellcheck disable=SC2064
trap "kill \$(jobs -p) 2>/dev/null; rm -rf '$DONE_DIR'; echo ''; log_info 'Log tailing stopped.'" INT TERM EXIT

for agent_id in $FOLLOW; do
    ns=$(agent_ns "$agent_id")
    color=$(agent_color "$agent_id")
    (
        oc_w logs -f deployment/"$agent_id" -n "$ns" 2>/dev/null | while IFS= read -r line; do
            printf "${color}[%-10s]${NC} %s\n" "$agent_id" "$line"
            # "done — idling" = finished its cycle budget (vs "stopped — idling")
            case "$line" in
                *"done — idling"*) touch "$DONE_DIR/$agent_id" ;;
            esac
        done
    ) &
done

# Watch for every followed agent finishing its cycle budget
while true; do
    sleep 3
    DONE_COUNT=$(find "$DONE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DONE_COUNT" -ge "$TOTAL" ]; then
        kill "$(jobs -p)" 2>/dev/null || true
        echo ""
        log_info "${D_PINK}All followed agents completed their cycles.${NC}"
        break
    fi
done
