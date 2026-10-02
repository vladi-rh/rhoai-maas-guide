#!/usr/bin/env bash
# Validate that all cross-cluster demo resources are in place and healthy.
set -euo pipefail

# shellcheck source=shared.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "    ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
check_fail() { echo -e "    ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "    ${YELLOW}⚠${NC} $*"; WARN=$((WARN + 1)); }

MAAS_CTX=""
WORKLOAD_CTX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --maas-context)     MAAS_CTX="$2"; shift 2 ;;
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./readiness-check.sh --maas-context <ctx> --workload-context <ctx>"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MAAS_CTX" ] || [ -z "$WORKLOAD_CTX" ]; then
    echo "Required: --maas-context, --workload-context"
    exit 1
fi

oc_m() { oc --context="$MAAS_CTX" "$@"; }
oc_w() { oc --context="$WORKLOAD_CTX" "$@"; }

echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Cross-Cluster Demo Readiness Check${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"

# =========================================================================
# MaaS Cluster checks
# =========================================================================
echo ""
echo -e "  ${BOLD}MaaS Cluster${NC} ${DIM}(${MAAS_CTX})${NC}"

# AuthPolicy: managed=false annotation required to prevent operator from restoring oidc-client-bound
MANAGED_ANNOTATION=$(oc_m get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    -o jsonpath='{.metadata.annotations.opendatahub\.io/managed}' 2>/dev/null || echo "")
if [ "$MANAGED_ANNOTATION" = "false" ]; then
    check_pass "AuthPolicy: opendatahub.io/managed=false annotation present"
else
    check_fail "AuthPolicy: opendatahub.io/managed annotation missing or not 'false' — operator may restore oidc-client-bound and reset model_access"
fi

# AuthPolicy: oidc-client-bound must be removed for per-agent Keycloak clients to work
OIDC_BOUND=$(oc_m get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    -o jsonpath='{.spec.defaults.rules.authorization.oidc-client-bound}' 2>/dev/null || echo "")
if [ -z "$OIDC_BOUND" ]; then
    check_pass "AuthPolicy: oidc-client-bound removed (per-agent clients allowed)"
else
    check_fail "AuthPolicy: oidc-client-bound still present — agents will get 403 on API key mint. Run: ./patch-authpolicy.sh --patch --maas-context ${MAAS_CTX}"
fi

# AuthPolicy: model_access must be populated (managed=false prevents operator from doing it)
MODEL_ACCESS_REGO=$(oc_m get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    -o jsonpath='{.spec.defaults.rules.authorization.require-group-membership.opa.rego}' 2>/dev/null || echo "")
if echo "$MODEL_ACCESS_REGO" | grep -q 'model_access := {}'; then
    check_fail "AuthPolicy: model_access is empty — agents will get 403 on inference. Run: ./patch-authpolicy.sh --patch --maas-context ${MAAS_CTX}"
elif echo "$MODEL_ACCESS_REGO" | grep -q 'model_access'; then
    check_pass "AuthPolicy: model_access populated (group-to-model mappings present)"
else
    check_warn "AuthPolicy: could not verify model_access — check manually"
fi

# Gateway
if oc_m get gateway agents-maas-gateway -n openshift-ingress &>/dev/null; then
    GW_HOST=$(oc_m get gateway agents-maas-gateway -n openshift-ingress \
        -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}' 2>/dev/null || echo "")
    HAS_ADDR=$(oc_m get gateway agents-maas-gateway -n openshift-ingress \
        -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [ -n "$HAS_ADDR" ]; then
        check_pass "Gateway agents-maas-gateway: https://${GW_HOST}"
    else
        check_warn "Gateway exists but has no address yet"
    fi
else
    check_fail "Gateway agents-maas-gateway not found"
fi

# AITenant
if oc_m get aitenant agents -n ai-tenants &>/dev/null; then
    READY=$(oc_m get aitenant agents -n ai-tenants \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$READY" = "True" ]; then
        check_pass "AITenant agents: Ready"
    else
        check_warn "AITenant agents exists but not Ready yet"
    fi
else
    check_fail "AITenant agents not found"
fi

# Tenant namespace
if oc_m get namespace ai-tenant-agents &>/dev/null; then
    check_pass "Namespace ai-tenant-agents exists"
else
    check_fail "Namespace ai-tenant-agents not found"
fi

# MaaSAuthPolicy
AUTH_COUNT=$(oc_m get maasauthpolicy -n ai-tenant-agents -o name 2>/dev/null | wc -l)
if [ "$AUTH_COUNT" -ge 3 ]; then
    check_pass "MaaSAuthPolicy: $AUTH_COUNT found"
else
    check_fail "MaaSAuthPolicy: expected >= 3, found $AUTH_COUNT"
fi

# MaaSSubscription
SUB_COUNT=$(oc_m get maassubscription -n ai-tenant-agents -o name 2>/dev/null | wc -l)
if [ "$SUB_COUNT" -ge 4 ]; then
    check_pass "MaaSSubscription: $SUB_COUNT found"
else
    check_fail "MaaSSubscription: expected >= 4, found $SUB_COUNT"
fi

# MaaSModelRef
if oc_m get maasmodelref -n ai-tenant-agents -o name &>/dev/null; then
    check_pass "MaaSModelRef exists in ai-tenant-agents"
else
    check_fail "MaaSModelRef not found in ai-tenant-agents"
fi

# =========================================================================
# Keycloak checks
# =========================================================================
echo ""
echo -e "  ${BOLD}Keycloak${NC}"

keycloak_discover "$MAAS_CTX"
KEYCLOAK_URL="$KC_URL"
if [ -z "$KC_URL" ]; then
    check_fail "Keycloak not found on MaaS cluster"
else
    ADMIN_TOKEN=$(keycloak_admin_token "$KC_URL" "$KC_NS" "$MAAS_CTX" 2>/dev/null || echo "")
    if [ -z "$ADMIN_TOKEN" ]; then
        check_fail "Could not get Keycloak admin token"
    else
        REALM_CHECK=$(curl -sSk -o /dev/null -w "%{http_code}" \
            "${KEYCLOAK_URL}/admin/realms/agent-realm" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}")
        if [ "$REALM_CHECK" = "200" ]; then
            check_pass "Keycloak agent-realm exists"
        else
            check_fail "Keycloak agent-realm not found (HTTP $REALM_CHECK)"
        fi

        CLIENT_COUNT=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/agent-realm/clients?first=0&max=100" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
            python3 -c "import sys,json; print(len([c for c in json.load(sys.stdin) if not c.get('name','').startswith('account')]))" 2>/dev/null || echo "0")
        if [ "$CLIENT_COUNT" -ge 5 ]; then
            check_pass "Keycloak clients: $CLIENT_COUNT found"
        else
            check_warn "Keycloak clients: expected >= 5, found $CLIENT_COUNT (includes built-in clients)"
        fi

        # Only count named groups (chatbots, code-reviewers, business-analysts) — not numeric GID leftovers
        NAMED_GROUPS=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/agent-realm/groups" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
            python3 -c "
import sys,json
gs = json.load(sys.stdin)
named = [g['name'] for g in gs if not g['name'].isdigit()]
print(len(named), ','.join(named))
" 2>/dev/null || echo "0 ")
        NAMED_COUNT="${NAMED_GROUPS%% *}"
        NAMED_LIST="${NAMED_GROUPS#* }"
        if [ "${NAMED_COUNT:-0}" -ge 3 ]; then
            check_pass "Keycloak groups: ${NAMED_LIST}"
        else
            check_fail "Keycloak groups: expected chatbots/code-reviewers/business-analysts, got: ${NAMED_LIST}"
        fi

        # Audience mapper
        AUD_MAPPER=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/agent-realm/client-scopes" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
            python3 -c "
import sys,json
for s in json.load(sys.stdin):
    for m in s.get('protocolMappers',[]):
        if m.get('protocolMapper')=='oidc-audience-mapper':
            print(m['config'].get('included.client.audience','?'))
" 2>/dev/null || echo "")
        if [ -n "$AUD_MAPPER" ]; then
            check_pass "Audience mapper present (aud: ${AUD_MAPPER})"
        else
            check_fail "Audience mapper missing — tokens will get HTTP 403 from MaaS"
        fi

        # Smoke test: mint a token
        TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/agent-realm/protocol/openid-connect/token"
        FIRST_CLIENT="chatbot-1"
        FIRST_UUID=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/agent-realm/clients?clientId=${FIRST_CLIENT}" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")
        if [ -n "$FIRST_UUID" ]; then
            FIRST_SECRET=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/agent-realm/clients/${FIRST_UUID}/client-secret" \
                -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))" 2>/dev/null || echo "")
            if [ -n "$FIRST_SECRET" ]; then
                TOKEN_RESPONSE=$(curl -sSk -X POST "$TOKEN_ENDPOINT" \
                    -d "grant_type=client_credentials" \
                    -d "client_id=${FIRST_CLIENT}" \
                    -d "client_secret=${FIRST_SECRET}" 2>/dev/null)
                ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
                if [ -n "$ACCESS_TOKEN" ]; then
                    TOKEN_GROUPS=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | python3 -c "
import sys, base64, json
b = sys.stdin.read().strip()
b += '=' * (4 - len(b) % 4)
d = json.loads(base64.urlsafe_b64decode(b))
print(','.join(d.get('groups',[])))
" 2>/dev/null || echo "")
                    check_pass "Token mint OK for $FIRST_CLIENT (groups: $TOKEN_GROUPS)"
                else
                    check_fail "Token mint failed for $FIRST_CLIENT"
                fi
            else
                check_warn "Could not retrieve client secret for $FIRST_CLIENT"
            fi
        else
            check_warn "Client $FIRST_CLIENT not found in agent-realm"
        fi
    fi
fi

# =========================================================================
# Workload Cluster checks
# =========================================================================
echo ""
echo -e "  ${BOLD}Workload Cluster${NC} ${DIM}(${WORKLOAD_CTX})${NC}"

NAMESPACES=(agents-chatbots agents-code-reviewers agents-business-analysts)
EXPECTED_PODS=("chatbot-1 chatbot-2" "reviewer-1 reviewer-2" "analyst-1")

for i in "${!NAMESPACES[@]}"; do
    ns="${NAMESPACES[$i]}"
    if oc_w get namespace "$ns" &>/dev/null; then
        check_pass "Namespace $ns exists"
        for dep in ${EXPECTED_PODS[$i]}; do
            READY=$(oc_w get deployment "$dep" -n "$ns" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
            if [ "${READY:-0}" -ge 1 ]; then
                check_pass "  Deployment $dep: Ready"
            elif oc_w get deployment "$dep" -n "$ns" &>/dev/null; then
                check_warn "  Deployment $dep: not Ready yet"
            else
                check_fail "  Deployment $dep: not found"
            fi
        done
    else
        check_fail "Namespace $ns not found"
    fi
done

# =========================================================================
# Summary
# =========================================================================
echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "    ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}  ${YELLOW}Warnings: ${WARN}${NC}  ${DIM}Total: ${TOTAL}${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
