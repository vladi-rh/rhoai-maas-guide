#!/usr/bin/env bash
# Remove all cross-cluster demo resources.
#
# Usage:
#   ./cleanup-demo.sh --maas-context <ctx>
#   ./cleanup-demo.sh --maas-context <ctx> --workload-context <ctx>
#
# Without --workload-context only the MaaS cluster is cleaned up.
# With --workload-context agent namespaces on the Workload cluster are also removed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

MAAS_CTX=""
WORKLOAD_CTX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --maas-context)     MAAS_CTX="$2";     shift 2 ;;
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[ -z "$MAAS_CTX" ] && { log_error "Required: --maas-context"; exit 1; }

oc_m() { oc --context="$MAAS_CTX" "$@"; }

keycloak_discover "$MAAS_CTX"
KEYCLOAK_URL="$KC_URL"
KEYCLOAK_NS="$KC_NS"

TENANT_NS="ai-tenant-agents"

# =========================================================================
# Step 1: Delete MaaS resources from tenant namespace
# =========================================================================
log_step 1 "Removing MaaS resources from $TENANT_NS"

for kind in maassubscription maasauthpolicy maasmodelref; do
    items=$(oc_m get "$kind" -n "$TENANT_NS" -o name 2>/dev/null || true)
    if [ -n "$items" ]; then
        echo "$items" | while read -r item; do
            log_info "Deleting $item"
            oc_m delete "$item" -n "$TENANT_NS" --ignore-not-found --wait=false
        done
    fi
done

# =========================================================================
# Step 2: Delete AITenant (operator will clean up namespace)
# =========================================================================
log_step 2 "Deleting AITenant 'agents' and tenant namespace"
oc_m delete aitenant agents -n ai-tenants --ignore-not-found --wait=false
oc_m delete namespace "$TENANT_NS" --ignore-not-found --wait=false
log_info "AITenant and namespace $TENANT_NS deletion requested"

# =========================================================================
# Step 3: Delete Gateway
# =========================================================================
log_step 3 "Deleting Gateway"
oc_m delete gateway agents-maas-gateway -n openshift-ingress --ignore-not-found --wait=false
log_info "Gateway deleted"

# =========================================================================
# Step 4: Delete Keycloak agent-realm
# =========================================================================
log_step 4 "Deleting Keycloak agent-realm"

if [ -z "$KEYCLOAK_URL" ]; then
    log_warn "Keycloak not found on cluster — skipping realm deletion"
else
    log_info "Keycloak: ${KEYCLOAK_URL} (${KEYCLOAK_NS})"
    ADMIN_TOKEN=$(keycloak_admin_token "$KEYCLOAK_URL" "$KEYCLOAK_NS" "$MAAS_CTX" 2>/dev/null || echo "")
    if [ -z "$ADMIN_TOKEN" ]; then
        log_warn "Could not get Keycloak admin token — skipping realm deletion"
    else
        HTTP_CODE=$(curl -sSk -o /dev/null -w "%{http_code}" -X DELETE \
            "${KEYCLOAK_URL}/admin/realms/agent-realm" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}")
        if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "404" ]; then
            log_info "Keycloak agent-realm deleted"
        else
            log_warn "Unexpected response deleting agent-realm: HTTP $HTTP_CODE"
        fi
    fi
fi

# =========================================================================
# Step 5: Detach agents gateway from model HTTPRoute
# =========================================================================
log_step 5 "Detaching agents gateway from model HTTPRoute"
MODEL_ROUTE="facebook-opt-125m-simulated-kserve-route"
PARENT_REFS=$(oc_m get httproute "$MODEL_ROUTE" -n llm \
    -o jsonpath='{range .spec.parentRefs[*]}{.name}{"\n"}{end}' 2>/dev/null || echo "")
if echo "$PARENT_REFS" | grep -q "agents-maas-gateway"; then
    # Remove agents-maas-gateway from parentRefs, keep others
    NEW_REFS=$(oc_m get httproute "$MODEL_ROUTE" -n llm -o json 2>/dev/null \
        | python3 -c "
import sys,json
d=json.load(sys.stdin)
d['spec']['parentRefs']=[r for r in d['spec']['parentRefs'] if r.get('name')!='agents-maas-gateway']
print(json.dumps(d['spec']['parentRefs']))
" 2>/dev/null || echo "")
    if [ -n "$NEW_REFS" ]; then
        oc_m patch httproute "$MODEL_ROUTE" -n llm \
            --type=merge -p "{\"spec\":{\"parentRefs\":${NEW_REFS}}}" > /dev/null 2>&1 \
            && log_info "Agents gateway removed from model HTTPRoute" \
            || log_warn "Could not remove agents gateway from HTTPRoute"
    fi
else
    log_info "Agents gateway not in model HTTPRoute — skipping"
fi

log_step 6 "Removing gateway-access namespace labels"
oc_m label namespace redhat-ai-gateway-infra maas.opendatahub.io/gateway-access-agents- 2>/dev/null || true
oc_m label namespace llm maas.opendatahub.io/gateway-access-agents- 2>/dev/null || true
log_info "Namespace labels removed"

# =========================================================================
# Step 7: Verify — wait briefly for operator, then force-clear if stuck
# =========================================================================
log_step 7 "Verifying cleanup"

NS_EXISTS=$(oc_m get namespace "$TENANT_NS" --ignore-not-found -o name 2>/dev/null || echo "")
GW_EXISTS=$(oc_m get gateway agents-maas-gateway -n openshift-ingress --ignore-not-found -o name 2>/dev/null || echo "")
AT_EXISTS=$(oc_m get aitenant agents -n ai-tenants --ignore-not-found -o name 2>/dev/null || echo "")

if [ -z "$NS_EXISTS" ] && [ -z "$GW_EXISTS" ] && [ -z "$AT_EXISTS" ]; then
    log_info "All resources removed"
else
    for i in $(seq 20 -1 1); do
        countdown_tick "$i" 20 "Giving operator time to process"
        sleep 1
    done
    printf "\r\033[K"

    NS_EXISTS=$(oc_m get namespace "$TENANT_NS" --ignore-not-found -o name 2>/dev/null || echo "")
    GW_EXISTS=$(oc_m get gateway agents-maas-gateway -n openshift-ingress --ignore-not-found -o name 2>/dev/null || echo "")
    AT_EXISTS=$(oc_m get aitenant agents -n ai-tenants --ignore-not-found -o name 2>/dev/null || echo "")

    if [ -z "$NS_EXISTS" ] && [ -z "$GW_EXISTS" ] && [ -z "$AT_EXISTS" ]; then
        log_info "All resources removed"
    else
        log_warn "Resources still terminating — force-clearing finalizers"

        if [ -n "$AT_EXISTS" ]; then
            oc_m patch aitenant agents -n ai-tenants \
                --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            log_info "AITenant finalizers cleared"
        fi

        if [ -n "$NS_EXISTS" ]; then
            for kind in maassubscription maasauthpolicy maasmodelref; do
                oc_m get "$kind" -n "$TENANT_NS" -o name 2>/dev/null | while read -r item; do
                    oc_m patch "$item" -n "$TENANT_NS" \
                        --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
                done
            done
            oc_m get namespace "$TENANT_NS" -o json 2>/dev/null \
                | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
                | oc_m replace --raw "/api/v1/namespaces/${TENANT_NS}/finalize" -f - > /dev/null 2>&1 || true
            log_info "Namespace finalizers cleared"
        fi

        if [ -n "$GW_EXISTS" ]; then
            oc_m patch gateway agents-maas-gateway -n openshift-ingress \
                --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            log_info "Gateway finalizers cleared"
        fi
    fi
fi

echo ""
log_info "MaaS cluster cleanup complete."

if [ -n "$WORKLOAD_CTX" ]; then
    echo ""
    "${DIR}/teardown-agents.sh" --workload-context "$WORKLOAD_CTX"
else
    log_info "To remove agent pods from the Workload cluster, run:"
    echo "  ./teardown-agents.sh --workload-context <ctx>"
fi
