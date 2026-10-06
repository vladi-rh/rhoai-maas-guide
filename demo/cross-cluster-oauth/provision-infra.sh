#!/usr/bin/env bash
# Provision the MaaS-side infrastructure for the cross-cluster agentic access demo.
#
# Creates: Gateway, AITenant, Keycloak agent-realm (groups + clients),
# MaaSModelRef, MaaSAuthPolicy, MaaSSubscription.
#
# Prerequisites:
#   - oc logged in with access to the MaaS cluster
#   - Keycloak already deployed (Phase 9 / setup-keycloak.sh)
#   - MaaS installed and working (Phases 1-5)
#
# Usage:
#   ./provision-infra.sh --maas-context <ctx> --keycloak-url <url> --keycloak-ns <ns>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

# ── Arguments ───────────────────────────────────────────────────────────
MAAS_CTX=""
KEYCLOAK_URL=""
KEYCLOAK_NS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --maas-context)  MAAS_CTX="$2";     shift 2 ;;
        --keycloak-url)  KEYCLOAK_URL="$2"; shift 2 ;;
        --keycloak-ns)   KEYCLOAK_NS="$2";  shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$MAAS_CTX" ] || [ -z "$KEYCLOAK_URL" ] || [ -z "$KEYCLOAK_NS" ]; then
    log_error "Required: --maas-context, --keycloak-url, --keycloak-ns"
    log_error "Use setup-demo.sh for interactive setup."
    exit 1
fi

oc_m() { oc --context="$MAAS_CTX" "$@"; }

TENANT_NAME="agents"
TENANT_NS="ai-tenant-agents"
GATEWAY_NAME="agents-maas-gateway"
REALM_NAME="agent-realm"
OIDC_CLIENT_ID="maas-agents"
MODEL_NAME="facebook-opt-125m-simulated"
MODEL_NS="llm"

# Hard ceiling on how long an API key minted against THIS tenant may live.
# This is the only server-enforced bound: clients choose their own expiresIn and maas-api
# honours it exactly, so the per-agent keyTtlSeconds values in profiles/ are advisory.
# 1 is the minimum the API allows — maxExpirationDays is day-granular ({"minimum": 1}),
# so a sub-day enforced ceiling cannot be expressed. Scoped to ai-tenant-agents only;
# the default tenant keeps its 90-day default.
API_KEY_MAX_EXPIRATION_DAYS="${API_KEY_MAX_EXPIRATION_DAYS:-1}"

# Agent groups and clients
REALM_GROUPS=("chatbots" "code-reviewers" "business-analysts")
declare -A GROUP_CLIENTS=(
    [chatbots]="chatbot-1 chatbot-2"
    [code-reviewers]="reviewer-1 reviewer-2"
    [business-analysts]="analyst-1"
)

# ── Targeting guards — fail loudly rather than touch the wrong tenant ───────
# Every MaaS tenant on a cluster has a MaasTenantConfig named "default-tenant"; only the
# namespace distinguishes the agents tenant from the default one. If TENANT_NS were ever
# empty, `-n ""` would silently fall back to the kubeconfig's current namespace and this
# script could reconfigure the default tenant (which the corporate-scenario demo relies on).
# Both are literals today, so this only fires if someone later makes them derived or
# user-supplied — which is exactly when it is needed.
if [ -z "${TENANT_NAME:-}" ] || [ -z "${TENANT_NS:-}" ]; then
    log_error "TENANT_NAME and TENANT_NS must both be non-empty" \
              "(got TENANT_NAME='${TENANT_NAME:-}' TENANT_NS='${TENANT_NS:-}')"
    exit 1
fi

# API_KEY_MAX_EXPIRATION_DAYS is env-overridable and is interpolated raw into a JSON patch
# body, so a non-numeric value would produce malformed JSON rather than an obvious error.
case "$API_KEY_MAX_EXPIRATION_DAYS" in
    ''|*[!0-9]*)
        log_error "API_KEY_MAX_EXPIRATION_DAYS must be a positive integer (got '${API_KEY_MAX_EXPIRATION_DAYS}')"
        exit 1 ;;
esac
if [ "$API_KEY_MAX_EXPIRATION_DAYS" -lt 1 ]; then
    log_error "API_KEY_MAX_EXPIRATION_DAYS must be >= 1 — the CRD enforces minimum: 1 (day-granular)"
    exit 1
fi

# ════════════════════════════════════════════════════════════════════════
log_section "Cross-Cluster Agentic Access — Infrastructure Provisioning"
# ════════════════════════════════════════════════════════════════════════

# ── Step 1: Detect cluster domain ───────────────────────────────────────
log_step 1 "Detecting cluster domain"

CLUSTER_DOMAIN=$(oc_m get ingresses.config/cluster -o jsonpath='{.spec.domain}')
AGENTS_HOSTNAME="agents-maas.${CLUSTER_DOMAIN}"
# Discover cert name from the existing default gateway (most reliable source)
CERT_NAME=$(oc_m get gateway maas-default-gateway -n openshift-ingress \
    -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs[0].name}' 2>/dev/null || echo "")
# Fallback: ingresscontroller default cert
if [ -z "$CERT_NAME" ]; then
    CERT_NAME=$(oc_m get ingresscontroller default -n openshift-ingress-operator \
        -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "router-certs-default")
fi

log_info "Cluster domain: ${BOLD}${CLUSTER_DOMAIN}${NC}"
log_info "Agents hostname: ${BOLD}${AGENTS_HOSTNAME}${NC}"
log_info "TLS cert:        ${BOLD}${CERT_NAME}${NC}"

# ── Step 2: Label namespaces for Gateway route access ──────────────────
log_step 2 "Labeling namespaces for gateway access"

oc_m label namespace redhat-ai-gateway-infra \
    "maas.opendatahub.io/gateway-access-${TENANT_NAME}=true" --overwrite > /dev/null
oc_m label namespace llm \
    "maas.opendatahub.io/gateway-access-${TENANT_NAME}=true" --overwrite > /dev/null
log_info "Namespaces labeled: redhat-ai-gateway-infra, llm"

# ── Step 3: Create Gateway ──────────────────────────────────────────────
log_step 3 "Creating Gateway"

sed "s|\${AGENTS_HOSTNAME}|${AGENTS_HOSTNAME}|g; s|\${CERT_NAME}|${CERT_NAME}|g" \
    "$DIR/manifests/gateway.yaml.tmpl" | oc_m apply -f - > /dev/null

log_info "Gateway ${BOLD}${GATEWAY_NAME}${NC} created in openshift-ingress"

# Attach agents gateway to the model's HTTPRoute so the operator can route
# inference requests through this tenant's gateway.
log_detail "Attaching agents gateway to model HTTPRoute in llm namespace..."
MODEL_ROUTE="facebook-opt-125m-simulated-kserve-route"
ALREADY_ATTACHED=$(oc_m get httproute "$MODEL_ROUTE" -n llm \
    -o jsonpath='{.spec.parentRefs[*].name}' 2>/dev/null | { grep -o "$GATEWAY_NAME" || true; })
if [ -n "$ALREADY_ATTACHED" ]; then
    log_info "Model HTTPRoute already references ${GATEWAY_NAME}"
else
    oc_m patch httproute "$MODEL_ROUTE" -n llm --type=json -p="[{
        \"op\": \"add\",
        \"path\": \"/spec/parentRefs/-\",
        \"value\": {
            \"group\": \"gateway.networking.k8s.io\",
            \"kind\": \"Gateway\",
            \"name\": \"${GATEWAY_NAME}\",
            \"namespace\": \"openshift-ingress\"
        }
    }]" 2>/dev/null && log_info "Model HTTPRoute patched to reference ${GATEWAY_NAME}" \
    || log_warn "Could not patch model HTTPRoute — subscriptions may stay Failed"
fi

# ── Step 4: Keycloak ────────────────────────────────────────────────────
log_step 4 "Keycloak"

KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/${REALM_NAME}"
log_info "URL:    ${BOLD}${KEYCLOAK_URL}${NC}"
log_info "NS:     ${BOLD}${KEYCLOAK_NS}${NC}"
log_info "Issuer: ${BOLD}${KEYCLOAK_ISSUER}${NC}"

# ── Step 5: Create AITenant ─────────────────────────────────────────────
log_step 5 "Creating AITenant"

sed "s|\${OIDC_CLIENT_ID}|${OIDC_CLIENT_ID}|g; s|\${KEYCLOAK_ISSUER}|${KEYCLOAK_ISSUER}|g" \
    "$DIR/manifests/aitenant.yaml.tmpl" | oc_m apply -f - > /dev/null

log_info "AITenant ${BOLD}${TENANT_NAME}${NC} created"

# Wait for tenant namespace
if oc_m get namespace "$TENANT_NS" &>/dev/null; then
    log_info "Namespace ${BOLD}${TENANT_NS}${NC} already exists"
else
    for i in $(seq 180 -3 3); do
        if oc_m get namespace "$TENANT_NS" &>/dev/null; then
            printf "\r\033[K"
            log_info "Namespace ${BOLD}${TENANT_NS}${NC} created by operator"
            break
        fi
        if [ "$i" -le 3 ]; then
            printf "\r\033[K"
            log_error "Timed out waiting for namespace $TENANT_NS"
            exit 1
        fi
        countdown_tick "$i" 180 "Waiting for namespace ${TENANT_NS}"
        sleep 3
    done
fi

# Label namespace for gateway access
oc_m label namespace "$TENANT_NS" \
    "maas.opendatahub.io/gateway-access-${TENANT_NAME}=true" --overwrite > /dev/null
log_info "Namespace labeled for gateway access"

# Wait for AITenant Ready
READY=$(oc_m get aitenant "$TENANT_NAME" -n ai-tenants \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$READY" = "True" ]; then
    log_info "AITenant is ${GREEN}Ready${NC}"
else
    for i in $(seq 180 -3 3); do
        READY=$(oc_m get aitenant "$TENANT_NAME" -n ai-tenants \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [ "$READY" = "True" ]; then
            printf "\r\033[K"
            log_info "AITenant is ${GREEN}Ready${NC}"
            break
        fi
        if [ "$i" -le 3 ]; then
            printf "\r\033[K"
            log_warn "AITenant not Ready after 180s — continuing anyway"
            break
        fi
        countdown_tick "$i" 180 "Waiting for AITenant to become Ready"
        sleep 3
    done
fi

# ── Step 5a: Cap API key lifetime for this tenant ───────────────────────
# The MaaS operator creates MaasTenantConfig/default-tenant in the tenant namespace once
# the AITenant reconciles. Lower its ceiling from the 90-day default so a client cannot
# mint a long-lived key. Idempotent; re-asserted on every run.
log_detail "Capping API key lifetime at ${API_KEY_MAX_EXPIRATION_DAYS} day(s)..."
for i in $(seq 60 -3 3); do
    if oc_m get maastenantconfig default-tenant -n "$TENANT_NS" &>/dev/null; then
        printf "\r\033[K"
        break
    fi
    countdown_tick "$i" 60 "Waiting for MaasTenantConfig"
    sleep 3
done

if oc_m get maastenantconfig default-tenant -n "$TENANT_NS" &>/dev/null; then
    oc_m patch maastenantconfig default-tenant -n "$TENANT_NS" --type=merge \
        -p "{\"spec\":{\"apiKeys\":{\"maxExpirationDays\":${API_KEY_MAX_EXPIRATION_DAYS}}}}" \
        > /dev/null 2>&1 || true
    # The operator reconciles this onto maas-api-<tenant> as API_KEY_MAX_EXPIRATION_DAYS
    # and rolls the deployment; keys live in Postgres so the restart is not disruptive.
    for i in $(seq 20 -1 1); do
        APPLIED=$(oc_m get deploy "maas-api-${TENANT_NAME}" -n redhat-ai-gateway-infra \
            -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="API_KEY_MAX_EXPIRATION_DAYS")].value}' \
            2>/dev/null || echo "")
        [ "$APPLIED" = "$API_KEY_MAX_EXPIRATION_DAYS" ] && break
        sleep 3
    done
    if [ "${APPLIED:-}" = "$API_KEY_MAX_EXPIRATION_DAYS" ]; then
        log_info "API key ceiling: ${BOLD}${API_KEY_MAX_EXPIRATION_DAYS} day(s)${NC} (was 90)"
    else
        log_warn "API key ceiling patch applied but not yet reconciled (deployment shows '${APPLIED:-unset}')"
    fi
else
    log_warn "MaasTenantConfig not found in ${TENANT_NS} — API key ceiling left at the default"
fi

# ── Step 5b: Patch AuthPolicy — narrow it to the agent clients ──────────
# The MaaS operator generates an oidc-client-bound rule pinned to a single client
# (azp == spec.oidc.clientId, i.e. maas-agents). Every per-agent token carries its own
# azp (chatbot-1, reviewer-1, ...), so the operator's single-value form 403s the whole
# fleet. This narrows it to an allowlist of exactly our clients instead of deleting it.
#
# Deleting it outright (the previous behaviour) left azp unchecked entirely. The comment
# that justified that — "aud already proves the token is for this gateway" — is wrong twice
# over: the policy sets no `audiences` on oidc-identities so aud is never validated, and the
# audience mapper lives on the realm's default `roles` scope, so every client in the realm
# gets the same aud anyway. aud cannot distinguish one client from another here.
log_detail "Patching AuthPolicy to allow per-agent Keycloak clients..."
AUTH_POLICY="agents-maas-gateway-maas-auth"
for i in $(seq 60 -3 3); do
    if oc_m get authpolicy "$AUTH_POLICY" -n openshift-ingress &>/dev/null; then
        printf "\r\033[K"
        break
    fi
    countdown_tick "$i" 60 "Waiting for AuthPolicy"
    sleep 3
done

if oc_m get authpolicy "$AUTH_POLICY" -n openshift-ingress &>/dev/null; then
    # 1. Opt out of MaaS operator management
    oc_m annotate authpolicy "$AUTH_POLICY" -n openshift-ingress \
        opendatahub.io/managed=false --overwrite > /dev/null

    # 2. Replace oidc-client-bound with a regex allowlist of our agent clients.
    #    The regex is built from GROUP_CLIENTS so it cannot drift from the clients this
    #    script actually creates. Anchored, so chatbot-1x / xchatbot-1 do not match.
    AGENT_CLIENT_RE="^($(printf '%s|' ${GROUP_CLIENTS[@]} | sed 's/|$//'))$"

    #    Built in Python, not hand-written JSON: the operator's `when` predicate contains
    #    nested quotes and double-escaped backslashes that shell quoting mangles easily.
    #    metrics/priority/when are byte-identical to the operator's own rule; only
    #    patternMatching differs (operator: matches + allowlist, vs eq + single client).
    #    JSON-patch `add` (not `replace`) so this works whether the rule is currently
    #    absent — as it is on a cluster provisioned by the previous version of this
    #    script — or present, as on a fresh install where the operator just generated it.
    OCB_PATCH=$(AGENT_RE="$AGENT_CLIENT_RE" python3 -c '
import json, os
rule = {
  "metrics": False,
  "priority": 1,
  "when": [{"predicate":
      "!request.headers.authorization.startsWith(\"Bearer sk-oai-\") && "
      "request.headers.authorization.matches(\"^Bearer [^.]+\\\\.[^.]+\\\\.[^.]+$\") && "
      "has(auth.identity.azp)"}],
  "patternMatching": {"patterns": [
      {"selector": "auth.identity.azp", "operator": "matches",
       "value": os.environ["AGENT_RE"]}]},
}
print(json.dumps([{"op": "add",
  "path": "/spec/defaults/rules/authorization/oidc-client-bound", "value": rule}]))')
    oc_m patch authpolicy "$AUTH_POLICY" -n openshift-ingress \
        --type=json -p "$OCB_PATCH" > /dev/null
    log_info "AuthPolicy patched — oidc-client-bound restricted to ${BOLD}${AGENT_CLIENT_RE}${NC}"

    # 2b. Drop the openshift-identities authentication rule.
    #     Without this, any OpenShift token (including a zero-RBAC ServiceAccount's)
    #     authenticates at this gateway and is only stopped later by maas-api, which
    #     returns 400 invalid_subscription. That match is by bare group-name string
    #     regardless of identity provider, so an OpenShift Group coincidentally named
    #     e.g. "chatbots" would grant mint rights. Removing the rule closes it at the
    #     door with a 401 instead.
    #
    #     Safe here: agents use Keycloak client-credentials JWTs, run-demo.sh execs
    #     agent.py in-pod (also Keycloak), check-gateway-wasm.sh expects 401/403 anyway,
    #     and the key-cleanup CronJobs bypass the gateway entirely (they curl the
    #     maas-api-agents Service directly). Trade-off: `oc whoami -t` can no longer be
    #     used to poke this gateway by hand.
    #
    #     AGENTS GATEWAY ONLY — the default gateway's corporate demo depends on
    #     OpenShift identities (corp-* and maas-demo-users subscriptions).
    oc_m patch authpolicy "$AUTH_POLICY" -n openshift-ingress \
        --type=json -p='[{"op":"remove","path":"/spec/defaults/rules/authentication/openshift-identities"}]' \
        > /dev/null 2>&1 || true
    log_info "AuthPolicy patched — openshift-identities authentication removed"

    # 3. Populate model_access in require-group-membership rego.
    #    managed=false prevents the operator from doing this via MaaSAuthPolicy,
    #    so we inject the group→model mapping manually. The MaaSAuthPolicy CRs stay
    #    Pending in that state ("opted out of controller management") and serve only
    #    as documentation of intended access — this rego is what is actually enforced.
    MODEL_REGO_KEY="${MODEL_NS}/${MODEL_NAME}"
    GROUPS_LIST=$(printf '"%s", ' "${REALM_GROUPS[@]}" | sed 's/, $//')

    CURRENT_REGO=$(oc_m get authpolicy "$AUTH_POLICY" -n openshift-ingress \
        -o jsonpath='{.spec.defaults.rules.authorization.require-group-membership.opa.rego}')

    if echo "$CURRENT_REGO" | grep -q 'model_access := {}'; then
        NEW_REGO=$(python3 -c "
import json, sys
rego = sys.stdin.read()
access = {'${MODEL_REGO_KEY}': {'groups': [${GROUPS_LIST}], 'users': []}}
rego = rego.replace('model_access := {}', 'model_access := ' + json.dumps(access), 1)
sys.stdout.write(rego)
" <<< "$CURRENT_REGO")
        PATCH_JSON=$(python3 -c "
import json, sys
rego = sys.stdin.read()
print(json.dumps([{'op': 'replace',
    'path': '/spec/defaults/rules/authorization/require-group-membership/opa/rego',
    'value': rego}]))
" <<< "$NEW_REGO")
        oc_m patch authpolicy "$AUTH_POLICY" -n openshift-ingress \
            --type=json -p="$PATCH_JSON" > /dev/null 2>&1
        log_info "AuthPolicy patched — model_access populated for ${MODEL_REGO_KEY}"
    else
        log_info "model_access already populated — skipping"
    fi
else
    log_warn "AuthPolicy not found — skipping patch (will need manual apply)"
fi

# ── Step 6: Create Keycloak agent-realm ─────────────────────────────────
log_step 6 "Creating Keycloak agent-realm"

ADMIN_TOKEN=$(keycloak_admin_token "$KEYCLOAK_URL" "$KEYCLOAK_NS" "$MAAS_CTX") \
    || { log_error "$ADMIN_TOKEN"; exit 1; }
log_info "Keycloak admin token acquired"

kc_api() {
    local method="$1" path="$2"
    shift 2
    curl -sSk -X "$method" "${KEYCLOAK_URL}/admin/realms${path}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        "$@"
}

# Create realm
log_detail "Creating realm: ${REALM_NAME}"
HTTP=$(kc_api POST "" -o /dev/null -w "%{http_code}" \
    -d "{\"realm\":\"${REALM_NAME}\",\"enabled\":true}")
if [ "$HTTP" = "201" ]; then
    log_info "Realm ${BOLD}${REALM_NAME}${NC} created"
elif [ "$HTTP" = "409" ]; then
    log_warn "Realm ${REALM_NAME} already exists"
else
    log_error "Failed to create realm (HTTP $HTTP)"
    exit 1
fi

# Add groups claim mapper to the realm's default client scope
log_detail "Adding groups claim protocol mapper"
DEFAULT_SCOPE_ID=$(kc_api GET "/${REALM_NAME}/client-scopes" | \
    python3 -c "import sys,json
scopes = json.load(sys.stdin)
for s in scopes:
    if s.get('name') == 'roles':
        print(s['id']); break
else:
    print('')")

if [ -n "$DEFAULT_SCOPE_ID" ]; then
    kc_api POST "/${REALM_NAME}/client-scopes/${DEFAULT_SCOPE_ID}/protocol-mappers/models" \
        -o /dev/null -w "" \
        -d '{
            "name": "groups",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-group-membership-mapper",
            "config": {
                "claim.name": "groups",
                "full.path": "false",
                "id.token.claim": "true",
                "access.token.claim": "true",
                "userinfo.token.claim": "true"
            }
        }' 2>/dev/null || true
    log_info "Groups claim mapper added"

    # Audience mapper — adds maas-agents to aud claim so MaaS accepts the token
    kc_api POST "/${REALM_NAME}/client-scopes/${DEFAULT_SCOPE_ID}/protocol-mappers/models" \
        -o /dev/null -w "" \
        -d '{
            "name": "maas-agents-audience",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-audience-mapper",
            "config": {
                "included.client.audience": "'"${OIDC_CLIENT_ID}"'",
                "id.token.claim": "false",
                "access.token.claim": "true"
            }
        }' 2>/dev/null || true
    log_info "Audience mapper added (aud: ${OIDC_CLIENT_ID})"
else
    log_warn "Could not find 'roles' client scope — adding realm-level mapper"
    kc_api POST "/${REALM_NAME}/components" \
        -o /dev/null -w "" \
        -d '{
            "name": "groups",
            "providerId": "oidc-group-membership-mapper",
            "providerType": "org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy",
            "config": {
                "claim.name": ["groups"],
                "full.path": ["false"],
                "id.token.claim": ["true"],
                "access.token.claim": ["true"]
            }
        }' 2>/dev/null || true
fi

# Create public client for MaaS audience validation
log_detail "Creating public client: ${OIDC_CLIENT_ID}"
HTTP=$(kc_api POST "/${REALM_NAME}/clients" -o /dev/null -w "%{http_code}" \
    -d "{
        \"clientId\": \"${OIDC_CLIENT_ID}\",
        \"enabled\": true,
        \"publicClient\": true,
        \"directAccessGrantsEnabled\": false,
        \"standardFlowEnabled\": false
    }")
if [ "$HTTP" = "201" ]; then
    log_info "Public client ${BOLD}${OIDC_CLIENT_ID}${NC} created"
elif [ "$HTTP" = "409" ]; then
    log_warn "Client ${OIDC_CLIENT_ID} already exists"
fi

# Delete any numeric-named groups left from previous bad runs (GIDs from bash GROUPS variable)
log_detail "Cleaning up any stale numeric groups from previous runs..."
kc_api GET "/${REALM_NAME}/groups" 2>/dev/null | python3 -c "
import sys,json
for g in json.load(sys.stdin):
    if g['name'].isdigit():
        print(g['id'])
" 2>/dev/null | while read -r gid; do
    kc_api DELETE "/${REALM_NAME}/groups/${gid}" -o /dev/null 2>/dev/null || true
    log_detail "  Deleted stale group: ${gid}"
done

# Create groups
for group in "${REALM_GROUPS[@]}"; do
    log_detail "Creating group: ${group}"
    HTTP=$(kc_api POST "/${REALM_NAME}/groups" -o /dev/null -w "%{http_code}" \
        -d "{\"name\":\"${group}\"}")
    if [ "$HTTP" = "201" ] || [ "$HTTP" = "409" ]; then
        log_info "Group ${BOLD}${group}${NC}: OK"
    else
        log_warn "Group ${group}: HTTP $HTTP"
    fi
done

# Get group IDs
declare -A GROUP_IDS
for group in "${REALM_GROUPS[@]}"; do
    GROUP_IDS[$group]=$(kc_api GET "/${REALM_NAME}/groups?search=${group}" | \
        python3 -c "import sys,json
groups = json.load(sys.stdin)
for g in groups:
    if g.get('name') == '${group}':
        print(g['id']); break
else:
    print('')")
done

# Create service-account clients and assign to groups
for group in "${REALM_GROUPS[@]}"; do
    for client_id in ${GROUP_CLIENTS[$group]}; do
        log_detail "Creating client: ${client_id}"
        HTTP=$(kc_api POST "/${REALM_NAME}/clients" -o /dev/null -w "%{http_code}" \
            -d "{
                \"clientId\": \"${client_id}\",
                \"enabled\": true,
                \"publicClient\": false,
                \"serviceAccountsEnabled\": true,
                \"directAccessGrantsEnabled\": false,
                \"standardFlowEnabled\": false,
                \"clientAuthenticatorType\": \"client-secret\"
            }")
        if [ "$HTTP" = "201" ]; then
            log_info "Client ${BOLD}${client_id}${NC} created"
        elif [ "$HTTP" = "409" ]; then
            log_warn "Client ${client_id} already exists"
        else
            log_warn "Client ${client_id}: HTTP $HTTP"
        fi

        # Get the internal client UUID
        CLIENT_UUID=$(kc_api GET "/${REALM_NAME}/clients?clientId=${client_id}" | \
            python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

        # Get the service account user
        SA_USER_ID=$(kc_api GET "/${REALM_NAME}/clients/${CLIENT_UUID}/service-account-user" | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

        # Assign to group only if not already a member
        GROUP_ID="${GROUP_IDS[$group]}"
        if [ -n "$GROUP_ID" ]; then
            ALREADY=$(kc_api GET "/${REALM_NAME}/users/${SA_USER_ID}/groups" | \
                python3 -c "import sys,json; print('yes' if any(g['id']=='${GROUP_ID}' for g in json.load(sys.stdin)) else '')" 2>/dev/null || echo "")
            if [ -n "$ALREADY" ]; then
                log_info "  → already in group ${MAGENTA}${group}${NC}"
            else
                kc_api PUT "/${REALM_NAME}/users/${SA_USER_ID}/groups/${GROUP_ID}" \
                    -o /dev/null 2>/dev/null || true
                log_info "  → assigned to group ${MAGENTA}${group}${NC}"
            fi
        fi
    done
done

# ── Step 7: Verify OIDC discovery ──────────────────────────────────────
log_step 7 "Verifying OIDC discovery"

HTTP_CODE=$(curl -sSk -o /dev/null -w "%{http_code}" \
    "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log_info "OIDC discovery endpoint is accessible"
else
    log_error "OIDC discovery returned HTTP $HTTP_CODE"
    exit 1
fi

# ── Step 8: Enable Kuadrant console plugin ─────────────────────────────
log_step 8 "Enabling Kuadrant console plugin"

if oc_m get consoleplugin kuadrant-console-plugin &>/dev/null; then
    oc_m patch consoles.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"plugins":["kuadrant-console-plugin"]}}' > /dev/null
    log_info "Kuadrant console plugin enabled"
else
    log_warn "kuadrant-console-plugin not found — skipping (installed by Kuadrant operator)"
fi

# ── Step 9: Apply MaaS resources ───────────────────────────────────────
log_step 9 "Applying MaaS resources"

subscription_ready() {
    local count
    count=$(oc_m get maassubscription -n "$TENANT_NS" \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | { grep "True" || true; } | wc -l | tr -d ' ')
    [ "${count:-0}" -ge 4 ]
}

start_spinner "Applying MaaS resources..."
oc_m apply -f "$DIR/manifests/modelref.yaml" > /dev/null
stop_spinner
log_info "MaaSModelRef applied"

log_subscription_warnings() {
    oc_m get maassubscription -n "$TENANT_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[*].message}{"\n"}{end}' \
        2>/dev/null | while IFS=$'\t' read -r name messages; do
        [ -z "$messages" ] && continue
        echo "$messages" | tr ';' '\n' | while IFS= read -r msg; do
            [ -n "$msg" ] && log_warn "  ${name}: ${msg}"
        done
    done
}

if subscription_ready; then
    log_info "MaaSAuthPolicy and MaaSSubscription already Ready — skipping apply"
else
    start_spinner "Applying subscriptions..."
    oc_m apply -f "$DIR/manifests/subscriptions.yaml" > /dev/null
    stop_spinner
    log_info "MaaSAuthPolicy and MaaSSubscription applied"

    for i in $(seq 90 -3 3); do
        if subscription_ready; then
            printf "\r\033[K"
            log_info "All subscriptions are ${GREEN}Ready${NC}"
            break
        fi
        FAILED_COUNT=$(oc_m get maassubscription -n "$TENANT_NS" \
            -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
            | { grep "Failed" || true; } | wc -l | tr -d ' ')
        if [ "${FAILED_COUNT:-0}" -gt 0 ]; then
            printf "\r\033[K"
            log_warn "Subscriptions in Failed state — operator error:"
            log_subscription_warnings
            break
        fi
        if [ "$i" -le 3 ]; then
            printf "\r\033[K"
            log_warn "Subscriptions not Ready after 90s:"
            log_subscription_warnings
            break
        fi
        countdown_tick "$i" 90 "Waiting for subscriptions to reconcile"
        sleep 3
    done
fi

# ════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}${CYAN}Infrastructure Provisioned${NC}"
echo -e "  ${DIM}${CYAN}─────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${BOLD}Keycloak${NC}"
echo -e "    URL:              ${KEYCLOAK_URL}"
echo -e "    Realm:            ${REALM_NAME}"
echo -e "    Token endpoint:   ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token"
echo ""
echo -e "  ${BOLD}MaaS (agents tenant)${NC}"
echo -e "    Gateway hostname: ${AGENTS_HOSTNAME}"
echo -e "    AITenant:         ${TENANT_NAME} (${TENANT_NS})"
echo -e "    OIDC client:      ${OIDC_CLIENT_ID}"
echo ""
echo -e "  ${BOLD}Agent clients${NC}"
for group in "${REALM_GROUPS[@]}"; do
    echo -e "    ${MAGENTA}${group}${NC}: ${GROUP_CLIENTS[$group]}"
done
echo ""
