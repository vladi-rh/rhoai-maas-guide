#!/usr/bin/env bash
# Interactive CLI demo walkthrough for cross-cluster agentic access.
#
# Usage:
#   ./run-demo.sh --maas-context <ctx> --workload-context <ctx> [--full]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

MAAS_CTX=""
WORKLOAD_CTX=""
FULL_MODE=false
SKIP_READINESS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --maas-context)     MAAS_CTX="$2"; shift 2 ;;
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        --full)             FULL_MODE=true; shift ;;
        --skip-readiness)   SKIP_READINESS=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MAAS_CTX" ] || [ -z "$WORKLOAD_CTX" ]; then
    log_error "Required: --maas-context, --workload-context"
    exit 1
fi

oc_m() { oc --context="$MAAS_CTX" "$@"; }

# =========================================================================
# Step 0: Readiness check (skipped on repeat runs)
# =========================================================================
if [ "$SKIP_READINESS" = false ]; then
    echo -e "  ${DIM}${CYAN}━━ Running readiness check...${NC}"
    if ! "${DIR}/readiness-check.sh" --maas-context "$MAAS_CTX" --workload-context "$WORKLOAD_CTX"; then
        log_error "Readiness check failed — fix issues above before running the demo."
        exit 1
    fi
fi

# =========================================================================
# Resolve endpoints
# =========================================================================
AGENTS_HOSTNAME=$(oc_m get gateway agents-maas-gateway -n openshift-ingress \
    -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}')
MAAS_URL="https://${AGENTS_HOSTNAME}"

keycloak_discover "$MAAS_CTX"
if [ -z "$KC_URL" ]; then
    log_error "Keycloak not found — has provision-infra.sh run?"
    exit 1
fi
KEYCLOAK_URL="$KC_URL"

pause() {
    echo ""
    printf "  ${DIM}Press Enter to continue...${NC} "
    read -r
    echo ""
}

# =========================================================================
# Select agents to demo
# =========================================================================
if [ "$FULL_MODE" = false ]; then
    DEMO_AGENTS=("chatbot-1" "chatbot-2" "reviewer-1")
else
    DEMO_AGENTS=("chatbot-1" "chatbot-2" "reviewer-1" "reviewer-2" "analyst-1")
fi

echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Cross-Cluster Agentic Access Demo${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""
echo -e "  MaaS Gateway:  ${BOLD}${MAAS_URL}${NC}"
echo -e "  Keycloak:      ${BOLD}${KEYCLOAK_URL}${NC}"
echo -e "  Agents:        ${BOLD}${DEMO_AGENTS[*]}${NC}"
echo ""

pause

# Map agent id -> namespace
agent_ns() {
    case "$1" in
        chatbot-*)  echo "agents-chatbots" ;;
        reviewer-*) echo "agents-code-reviewers" ;;
        analyst-*)  echo "agents-business-analysts" ;;
    esac
}

# =========================================================================
# Per-agent walkthrough — executed inside the actual agent pod
# =========================================================================
for agent_id in "${DEMO_AGENTS[@]}"; do
    ns=$(agent_ns "$agent_id")
    echo ""
    echo -e "  ${D_PINK}───────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${D_PINK}Agent: ${agent_id}  (${ns})${NC}"
    echo -e "  ${D_PINK}───────────────────────────────────────────${NC}"

    echo -e "  ${BOLD}${CYAN}━━ 1+2+3${NC} ${BOLD}Token mint → JWT claims → Inference (inside pod)${NC}"

    POD_NAME=$(oc --context="$WORKLOAD_CTX" get pods -n "$ns" \
        -l "agent-id=${agent_id}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$POD_NAME" ]; then
        log_warn "No pod found for ${agent_id} — is provision-agents.sh complete?"
        continue
    fi
    POD_LOG=$(oc --context="$WORKLOAD_CTX" exec -n "$ns" "$POD_NAME" -- \
        python3 /opt/agent/agent.py --demo 2>&1 || echo "exec failed")

    echo "$POD_LOG" | while IFS= read -r line; do
        echo -e "    ${D_GREEN}${line}${NC}"
    done

    pause
done

# =========================================================================
# Subscription priority demo
# =========================================================================
echo ""
echo -e "  ${DIM}${CYAN}───────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Subscription Priority Demo${NC}"
echo -e "  ${DIM}${CYAN}───────────────────────────────────────────${NC}"
echo ""

echo -e "  ${BOLD}Comparing:${NC} chatbot-1 (group default: ${YELLOW}500 t/min${NC}) vs chatbot-2 (override: ${GREEN}2000 t/min${NC})"

echo ""
log_info "MaaSSubscriptions in ai-tenant-agents:"
oc_m get maassubscription -n ai-tenant-agents \
    -o custom-columns='NAME:.metadata.name,PRIORITY:.spec.priority' 2>/dev/null || true

echo ""
log_info "chatbot-1 inherits group rate limit (priority 35)"
log_info "chatbot-2 has a per-agent override (priority 50) — higher priority wins"

echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Demo Complete${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""
echo "  To start autonomous agent traffic:"
echo "    ./start-agents.sh --workload-context ${WORKLOAD_CTX}"
echo ""
echo "  To clean up:"
echo "    ./teardown-agents.sh --workload-context ${WORKLOAD_CTX}"
echo "    ./cleanup-demo.sh --maas-context ${MAAS_CTX}"
echo ""

printf "  ${BOLD}${D_GREEN}▶${NC} Run the demo again? [y/N]: "
read -r AGAIN
case "$AGAIN" in
    [yY]|[yY][eE][sS])
        echo ""
        exec "$0" --maas-context "$MAAS_CTX" --workload-context "$WORKLOAD_CTX" \
            --skip-readiness $( [ "$FULL_MODE" = true ] && echo --full )
        ;;
esac
echo ""
