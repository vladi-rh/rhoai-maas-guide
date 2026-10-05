#!/usr/bin/env bash
# Interactive setup for the cross-cluster agentic access demo.
#
# Asks for cluster contexts and endpoints, then calls:
#   1. provision-infra.sh  — Gateway, AITenant, Keycloak realm, subscriptions
#   2. provision-agents.sh — Deploy agent pods on the Workload cluster
#   3. readiness-check.sh  — Validate everything is in place
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_KC="$(dirname "$(dirname "$DIR")")/manifests/09-external-oidc/setup-keycloak.sh"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

# Temp file accumulates found Keycloak instances: one "label|ctx|ns|name|url" per line.
KC_TMPFILE=$(mktemp)
trap 'rm -f "$KC_TMPFILE"' EXIT

# Scan one cluster for all Keycloak CRs. Appends found instances to KC_TMPFILE.
# Prints status as it goes so the user sees progress immediately.
# Usage: detect_keycloak <context> <label>
detect_keycloak() {
    local ctx="$1" label="$2"

    start_spinner "Searching for Keycloak on ${label}"

    local entries
    entries=$(oc --context="$ctx" get keycloak -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || echo "")

    if [ -z "$entries" ]; then
        stop_spinner
        echo -e "    ${DIM}no Keycloak instance found${NC}"
        return
    fi

    local ns name all_hosts host
    while IFS=$'\t' read -r ns name; do
        [ -z "$ns" ] && continue

        all_hosts=$(oc --context="$ctx" get route -n "$ns" \
            -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null || echo "")

        host=$(printf '%s\n' "$all_hosts" | grep -i "$name" | head -1 || true)
        [ -z "$host" ] && host=$(printf '%s\n' "$all_hosts" | head -1 || true)

        stop_spinner
        if [ -n "$host" ]; then
            echo "${label}|${ctx}|${ns}|${name}|https://${host}" >> "$KC_TMPFILE"
            log_info "  Found: https://${host}  ${DIM}(${ns}/${name})${NC}"
        else
            echo -e "    ${DIM}  CR ${ns}/${name} found but no route available yet${NC}"
        fi
    done <<< "$entries"
}

# =========================================================================
echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Cross-Cluster Agentic Access — Setup${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""

# =========================================================================
# Show available contexts
# =========================================================================
CURRENT_CTX=$(oc config current-context 2>/dev/null || echo "")
ALL_CTXS=$(oc config get-contexts --no-headers -o name 2>/dev/null || echo "")

# Suggest well-known names if they exist, otherwise fall back to current
DEFAULT_MAAS="maas"
DEFAULT_WORKLOAD="workload"
echo "$ALL_CTXS" | grep -qx "$DEFAULT_MAAS"     || DEFAULT_MAAS="$CURRENT_CTX"
echo "$ALL_CTXS" | grep -qx "$DEFAULT_WORKLOAD"  || DEFAULT_WORKLOAD=""

echo -e "  ${BOLD}Recent oc contexts (last 5):${NC}"
echo -e "  ${DIM}Pick your clusters — the CLUSTER column shows the API server hostname.${NC}"
echo ""
CTX_OUTPUT=$(oc config get-contexts 2>/dev/null || true)
CTX_HEADER=$(echo "$CTX_OUTPUT" | head -1)
CTX_LINES=$(echo "$CTX_OUTPUT" | tail -n +2)
CTX_TOTAL=$(echo "$CTX_LINES" | grep -c . || true)
echo -e "    ${DIM}${CTX_HEADER}${NC}"
echo "$CTX_LINES" | tail -5 | while IFS= read -r line; do
    echo "    $line"
done
if [ "$CTX_TOTAL" -gt 5 ]; then
    echo -e "    ${DIM}... ($((CTX_TOTAL - 5)) more — run 'oc config get-contexts' to see all)${NC}"
fi
echo ""

# =========================================================================
# MaaS cluster context
# =========================================================================
echo -e "  ${BOLD}MaaS cluster${NC} ${DIM}— hosts MaaS, Keycloak, AITenant, Gateway${NC}"
printf "  Select cluster context [%s]: " "$DEFAULT_MAAS"
read -r MAAS_CTX
MAAS_CTX="${MAAS_CTX:-$DEFAULT_MAAS}"

if [ -z "$MAAS_CTX" ]; then
    log_error "MaaS cluster context is required."
    exit 1
fi
if ! oc --context="$MAAS_CTX" whoami &>/dev/null; then
    log_error "Cannot connect with context '${MAAS_CTX}' — check your oc login."
    exit 1
fi
log_info "MaaS cluster: $MAAS_CTX"

CLUSTER_DOMAIN=$(oc --context="$MAAS_CTX" get ingresses.config.openshift.io cluster \
    -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -n "$CLUSTER_DOMAIN" ]; then
    log_info "Cluster domain: $CLUSTER_DOMAIN"
else
    echo -e "  ${DIM}Could not auto-detect cluster domain${NC}"
fi

detect_keycloak "$MAAS_CTX" "MaaS cluster"

# =========================================================================
# Workload cluster context
# =========================================================================
echo ""
echo -e "  ${BOLD}Workload cluster${NC} ${DIM}— hosts agent pods, typically a separate cluster from MaaS${NC}"
printf "  Select cluster context [%s]: " "${DEFAULT_WORKLOAD:-none}"
read -r WORKLOAD_CTX
[ -z "$WORKLOAD_CTX" ] && [ -n "$DEFAULT_WORKLOAD" ] && WORKLOAD_CTX="$DEFAULT_WORKLOAD"

if [ -z "$WORKLOAD_CTX" ]; then
    log_error "Workload cluster context is required."
    exit 1
fi
if ! oc --context="$WORKLOAD_CTX" whoami &>/dev/null; then
    log_error "Cannot connect with context '${WORKLOAD_CTX}' — check your oc login."
    exit 1
fi
log_info "Workload cluster: $WORKLOAD_CTX"

detect_keycloak "$WORKLOAD_CTX" "Workload cluster"

# =========================================================================
# Cluster domain (ask if not auto-detected)
# =========================================================================
if [ -z "$CLUSTER_DOMAIN" ]; then
    echo ""
    printf "  Enter cluster domain (e.g. apps.cluster.example.com): "
    read -r CLUSTER_DOMAIN
    [ -z "$CLUSTER_DOMAIN" ] && { log_error "Cluster domain is required."; exit 1; }
fi

AGENTS_HOSTNAME="agents-maas.${CLUSTER_DOMAIN}"
MAAS_URL="https://${AGENTS_HOSTNAME}"

# =========================================================================
# Resolve Keycloak URL from discovered instances
# =========================================================================
oc_m() { oc --context="$MAAS_CTX" "$@"; }
KEYCLOAK_URL=""
KEYCLOAK_NS=""
KC_COUNT=$(wc -l < "$KC_TMPFILE" | tr -d ' ')

if [ "$KC_COUNT" -eq 0 ]; then
    echo ""
    log_warn "No Keycloak instance found on either cluster."
    echo -e "  Keycloak is required for the agent-realm OIDC flow."
    echo -e "  In which cluster should it be deployed?"
    echo -e "    ${BOLD}1)${NC} MaaS cluster     (${MAAS_CTX})  ${DIM}— recommended${NC}"
    echo -e "    ${BOLD}2)${NC} Workload cluster  (${WORKLOAD_CTX})"
    echo -e "    ${BOLD}3)${NC} Skip — I will deploy it manually"
    while true; do
        printf "  Choose [1/2/3]: "
        read -r DEPLOY_CHOICE
        case "$DEPLOY_CHOICE" in
            1|2)
                deploy_ctx="$MAAS_CTX"
                [ "$DEPLOY_CHOICE" = "2" ] && deploy_ctx="$WORKLOAD_CTX"
                echo ""
                log_info "Deploying Keycloak on context: ${deploy_ctx}..."
                if [ -f "$SETUP_KC" ]; then
                    bash "$SETUP_KC" --maas-context "$deploy_ctx"
                    detect_keycloak "$deploy_ctx" "newly deployed"
                    KC_COUNT=$(wc -l < "$KC_TMPFILE" | tr -d ' ')
                    if [ "$KC_COUNT" -eq 0 ]; then
                        log_error "Keycloak deployed but URL not found."
                        exit 1
                    fi
                    KC_LAST=$(tail -1 "$KC_TMPFILE")
                    KEYCLOAK_URL=$(echo "$KC_LAST" | cut -d'|' -f5)
                    KEYCLOAK_NS=$(echo "$KC_LAST" | cut -d'|' -f3)
                else
                    log_error "setup-keycloak.sh not found at: $SETUP_KC"
                    exit 1
                fi
                break ;;
            3)
                log_warn "Deploy Keycloak first, then re-run this script."
                echo "    manifests/09-external-oidc/setup-keycloak.sh"
                exit 0 ;;
            *) log_warn "Enter 1, 2, or 3." ;;
        esac
    done

elif [ "$KC_COUNT" -eq 1 ]; then
    KC_ENTRY=$(cat "$KC_TMPFILE")
    KEYCLOAK_URL="${KC_ENTRY##*|}"
    KEYCLOAK_NS=$(echo "$KC_ENTRY" | cut -d'|' -f3)
    echo ""
    printf "  Use this Keycloak instance (%s)? [Y/n]: " "$KEYCLOAK_URL"
    read -r KC_CONFIRM
    case "$KC_CONFIRM" in
        [nN]*)
            log_warn "Deploy a different Keycloak instance and re-run this script."
            exit 0 ;;
    esac

else
    echo ""
    echo -e "  ${BOLD}Multiple Keycloak instances found — choose one:${NC}"
    idx=1
    while IFS= read -r entry; do
        label="${entry%%|*}"
        url="${entry##*|}"
        echo -e "    ${BOLD}${idx})${NC} ${url}  ${DIM}(${label})${NC}"
        idx=$((idx + 1))
    done < "$KC_TMPFILE"
    while true; do
        printf "  Choose [1-%d]: " "$KC_COUNT"
        read -r KC_CHOICE
        if [[ "$KC_CHOICE" =~ ^[0-9]+$ ]] && \
           [ "$KC_CHOICE" -ge 1 ] && [ "$KC_CHOICE" -le "$KC_COUNT" ]; then
            KC_ENTRY=$(sed -n "${KC_CHOICE}p" "$KC_TMPFILE")
            KEYCLOAK_URL="${KC_ENTRY##*|}"
            KEYCLOAK_NS=$(echo "$KC_ENTRY" | cut -d'|' -f3)
            break
        fi
        log_warn "Enter a number between 1 and ${KC_COUNT}."
    done
fi

log_info "Keycloak: $KEYCLOAK_URL"

# =========================================================================
# Confirm
# =========================================================================
echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  MaaS cluster:   ${BOLD}${MAAS_CTX}${NC}"
echo -e "  Workload:       ${BOLD}${WORKLOAD_CTX}${NC}"
echo -e "  Agents gateway: ${BOLD}${MAAS_URL}${NC}  ${DIM}(dedicated entry point for inference calls)${NC}"
echo -e "  Keycloak:       ${BOLD}${KEYCLOAK_URL}${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""
printf "  ${BOLD}Proceed? [Y/n]:${NC} "
read -r CONFIRM
case "$CONFIRM" in
    [nN]|[nN][oO]) log_info "Aborted."; exit 0 ;;
esac

# =========================================================================
# Phase 1: Provision infrastructure on MaaS cluster
# =========================================================================
echo ""
echo -e "  ${BOLD}${CYAN}━━ Phase 1${NC} ${BOLD}Provisioning infrastructure on MaaS cluster${NC}"
echo ""

"${DIR}/provision-infra.sh" \
    --maas-context "$MAAS_CTX" \
    --keycloak-url "$KEYCLOAK_URL" \
    --keycloak-ns "$KEYCLOAK_NS"

# =========================================================================
# Phase 2: Provision agents on Workload cluster
# =========================================================================
echo ""
echo -e "  ${DIM}${MAGENTA}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${MAGENTA}Phase 2 — Agent pods on Workload cluster (${WORKLOAD_CTX})${NC}"
echo -e "  ${DIM}${MAGENTA}─────────────────────────────────────────────${NC}"
echo ""
echo -e "    MaaS URL:     ${BOLD}${MAAS_URL}${NC}"
echo -e "    Keycloak URL: ${BOLD}${KEYCLOAK_URL}${NC}"
echo -e "    Context:      ${BOLD}${WORKLOAD_CTX}${NC}"
echo ""
printf "  ${BOLD}${MAGENTA}Deploy agent pods to Workload cluster? [Y/n]:${NC} "
read -r CONFIRM2
case "$CONFIRM2" in
    [nN]|[nN][oO]) log_info "Aborted."; exit 0 ;;
esac

"${DIR}/provision-agents.sh" \
    --workload-context "$WORKLOAD_CTX" \
    --maas-context "$MAAS_CTX" \
    --maas-url "$MAAS_URL" \
    --keycloak-url "$KEYCLOAK_URL" \
    --keycloak-ns "$KEYCLOAK_NS"

# =========================================================================
# Phase 3: Agent console
# =========================================================================
echo ""
echo -e "  ${BOLD}${CYAN}━━ Phase 3${NC} ${BOLD}Deploying agent console${NC}"

"${DIR}/provision-console.sh" --workload-context "$WORKLOAD_CTX"

# =========================================================================
# Phase 4: Readiness check
# =========================================================================
echo ""
echo -e "  ${BOLD}${CYAN}━━ Phase 4${NC} ${BOLD}Running readiness check${NC}"
echo ""

"${DIR}/readiness-check.sh" --maas-context "$MAAS_CTX" --workload-context "$WORKLOAD_CTX"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Setup Complete${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""
CONSOLE_URL=$(console_url "$WORKLOAD_CTX")

echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    ${GREEN}1.${NC} Run the demo walkthrough:"
echo -e "       ./run-demo.sh --maas-context ${MAAS_CTX} --workload-context ${WORKLOAD_CTX}"
echo ""
echo -e "    ${GREEN}2.${NC} Start autonomous agent traffic:"
if [ -n "$CONSOLE_URL" ]; then
    echo -e "       Agent console: ${BOLD}${D_PINK}${CONSOLE_URL}${NC}"
    echo -e "       ${DIM}or${NC} ./start-agents.sh --workload-context ${WORKLOAD_CTX}"
else
    echo -e "       ./start-agents.sh --workload-context ${WORKLOAD_CTX}"
fi
echo -e "       ${DIM}tail logs:${NC} ./follow-agents.sh --workload-context ${WORKLOAD_CTX}"
echo ""
echo -e "    ${GREEN}3.${NC} Clean up:"
echo -e "       ./teardown-agents.sh --workload-context ${WORKLOAD_CTX}"
echo -e "       ./cleanup-demo.sh --maas-context ${MAAS_CTX}"
echo ""
