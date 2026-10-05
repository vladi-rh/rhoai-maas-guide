#!/usr/bin/env bash
# Deploy agent pods on the Workload cluster.
#
# Assumes provision-infra.sh has already run (Keycloak realm + MaaS subscriptions).
#
# Usage:
#   ./provision-agents.sh --workload-context <ctx> --maas-context <ctx> --maas-url <url> --keycloak-url <url> --keycloak-ns <ns>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

WORKLOAD_CTX=""
MAAS_CTX=""
MAAS_URL=""
KEYCLOAK_URL=""
KEYCLOAK_NS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
        --maas-context)     MAAS_CTX="$2";     shift 2 ;;
        --maas-url)         MAAS_URL="$2";      shift 2 ;;
        --keycloak-url)     KEYCLOAK_URL="$2";  shift 2 ;;
        --keycloak-ns)      KEYCLOAK_NS="$2";   shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$WORKLOAD_CTX" ] || [ -z "$MAAS_CTX" ] || [ -z "$MAAS_URL" ] || [ -z "$KEYCLOAK_URL" ] || [ -z "$KEYCLOAK_NS" ]; then
    log_error "Required: --workload-context, --maas-context, --maas-url, --keycloak-url, --keycloak-ns"
    exit 1
fi

oc_w() { oc --context="$WORKLOAD_CTX" "$@"; }

REALM_NAME="agent-realm"
KEYCLOAK_TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token"

# Agent categories: group -> list of client names
declare -A AGENT_GROUPS=(
    [chatbots]="chatbot-1 chatbot-2"
    [code-reviewers]="reviewer-1 reviewer-2"
    [business-analysts]="analyst-1"
)

# Map group -> namespace and profile
declare -A GROUP_NS=(
    [chatbots]=agents-chatbots
    [code-reviewers]=agents-code-reviewers
    [business-analysts]=agents-business-analysts
)

declare -A GROUP_PROFILE=(
    [chatbots]=chatbot-profile.yaml
    [code-reviewers]=reviewer-profile.yaml
    [business-analysts]=analyst-profile.yaml
)


CONTROL_PORT=8080
# Lifetime of each agent's minted MaaS API key. Shorter = shorter revocation tail and
# faster detection if minting breaks; longer = rides out an upstream outage for longer.
# maas-api imposes no minimum and honours this value exactly, so it is advisory; the only
# enforced cap is the tenant's maxExpirationDays, set to 1 day by provision-infra.sh.
# Per-group overrides: keyTtlSeconds in profiles/*.yaml.
KEY_TTL_SECONDS="${KEY_TTL_SECONDS:-300}"

# Hash the agent script into the pod template so a code change triggers a rollout.
# (A ConfigMap update alone does not restart pods.)
file_hash() {
    python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$1"
}
SCRIPT_HASH=$(file_hash "${DIR}/agent/agent.py")

get_client_secret() {
    local client_id="$1"
    local admin_token="$2"
    local client_uuid
    client_uuid=$(curl -sSk "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id}" \
        -H "Authorization: Bearer ${admin_token}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
    curl -sSk "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${client_uuid}/client-secret" \
        -H "Authorization: Bearer ${admin_token}" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])"
}

# =============================================================================
# Step 1: Get admin token
# =============================================================================
log_step 1 "Getting Keycloak admin token"
ADMIN_TOKEN=$(keycloak_admin_token "$KEYCLOAK_URL" "$KEYCLOAK_NS" "$MAAS_CTX") \
    || { log_error "$ADMIN_TOKEN"; exit 1; }
log_info "Admin token acquired"

# =============================================================================
# Step 2: Create namespaces and ConfigMaps
# =============================================================================
log_step 2 "Creating agent namespaces and ConfigMaps"

for group in "${!AGENT_GROUPS[@]}"; do
    ns="${GROUP_NS[$group]}"
    profile="${GROUP_PROFILE[$group]}"

    log_info "Creating namespace: $ns"
    oc_w new-project "$ns" > /dev/null 2>&1 || true
    oc_w label namespace "$ns" demo=cross-cluster-oauth --overwrite > /dev/null 2>&1 || true


    # Profile: always re-apply. It used to be create-if-missing so in-cluster hand-tuning
    # survived, but that silently blocks new profile keys (keyTtlSeconds) from ever
    # reaching an existing namespace. The repo is the source of truth; re-run to re-assert.
    log_info "Applying behavior profile ConfigMap in $ns"
    oc_w create configmap agent-profile -n "$ns" \
        --from-file=profile.yaml="${DIR}/profiles/${profile}" \
        --dry-run=client -o yaml | oc_w apply -f - > /dev/null

    # Script: always re-apply — it is code, and the repo is the source of truth
    log_info "Applying agent script ConfigMap in $ns"
    oc_w create configmap agent-script -n "$ns" \
        --from-file=agent.py="${DIR}/agent/agent.py" \
        --dry-run=client -o yaml | oc_w apply -f - > /dev/null
done

# =============================================================================
# Step 3: Deploy agent pods
# =============================================================================
log_step 3 "Deploying agent pods"

for group in "${!AGENT_GROUPS[@]}"; do
    ns="${GROUP_NS[$group]}"
    # Pod template hash must cover the profile too, not just agent.py — otherwise a
    # changed keyTtlSeconds updates the ConfigMap but never restarts the pod that
    # reads it at boot, and the change silently does nothing.
    POD_HASH="${SCRIPT_HASH}$(file_hash "${DIR}/profiles/${GROUP_PROFILE[$group]}")"
    for client_id in ${AGENT_GROUPS[$group]}; do
        log_info "Fetching client secret for $client_id"
        CLIENT_SECRET=$(get_client_secret "$client_id" "$ADMIN_TOKEN")

        log_info "Creating credentials secret for $client_id in $ns"
        oc_w delete secret "${client_id}-creds" -n "$ns" --ignore-not-found 2>/dev/null || true
        oc_w create secret generic "${client_id}-creds" -n "$ns" \
            --from-literal=client_id="$client_id" \
            --from-literal=client_secret="$CLIENT_SECRET" \
            --from-literal=token_endpoint="$KEYCLOAK_TOKEN_ENDPOINT"

        log_info "Deploying: $client_id in $ns"
        cat <<EOF | oc_w apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${client_id}
  namespace: ${ns}
  labels:
    app: maas-agent
    demo: cross-cluster-oauth
    type: ai-agent
    agent-group: ${group}
    agent-id: ${client_id}
spec:
  replicas: 1
  selector:
    matchLabels:
      agent-id: ${client_id}
  template:
    metadata:
      annotations:
        agent-pod-hash: "${POD_HASH}"
      labels:
        app: maas-agent
        demo: cross-cluster-oauth
        type: ai-agent
        agent-group: ${group}
        agent-id: ${client_id}
    spec:
      containers:
        - name: agent
          image: registry.access.redhat.com/ubi9/python-39:latest
          command: ["python3", "/opt/agent/agent.py"]
          ports:
            - name: control
              containerPort: ${CONTROL_PORT}
          readinessProbe:
            httpGet: { path: /healthz, port: control }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: control }
            initialDelaySeconds: 10
            periodSeconds: 20
          env:
            - name: AGENT_GROUP
              value: "${group}"
            - name: CONTROL_PORT
              value: "${CONTROL_PORT}"
            - name: AUTOSTART
              value: "false"
            - name: KEY_TTL_SECONDS
              value: "${KEY_TTL_SECONDS}"
            - name: CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: ${client_id}-creds
                  key: client_id
            - name: CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: ${client_id}-creds
                  key: client_secret
            - name: KEYCLOAK_TOKEN_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: ${client_id}-creds
                  key: token_endpoint
            - name: MAAS_URL
              value: "${MAAS_URL}"
            - name: MODEL_NAME
              value: "facebook/opt-125m"
            - name: MODEL_PATH
              value: "facebook-opt-125m-simulated"
            - name: PROFILE_PATH
              value: "/etc/agent/profile.yaml"
          volumeMounts:
            - name: agent-script
              mountPath: /opt/agent
            - name: agent-profile
              mountPath: /etc/agent
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: agent-script
          configMap:
            name: agent-script
        - name: agent-profile
          configMap:
            name: agent-profile
---
apiVersion: v1
kind: Service
metadata:
  name: ${client_id}
  namespace: ${ns}
  labels:
    app: maas-agent
    demo: cross-cluster-oauth
    agent-id: ${client_id}
spec:
  selector:
    agent-id: ${client_id}
  ports:
    - name: control
      port: ${CONTROL_PORT}
      targetPort: control
EOF
    done
done

# =============================================================================
# Step 4: Wait for agent deployments to become ready
# =============================================================================
log_step 4 "Waiting for agent deployments to become ready"

deploy_ready() {
    local client_id="$1" ns="$2"
    local ready
    ready=$(oc_w get deployment "$client_id" -n "$ns" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "${ready:-0}" -ge 1 ]
}

for group in "${!AGENT_GROUPS[@]}"; do
    ns="${GROUP_NS[$group]}"
    for client_id in ${AGENT_GROUPS[$group]}; do
        if deploy_ready "$client_id" "$ns"; then
            log_info "${BOLD}${client_id}${NC} (${ns}): ${GREEN}Ready${NC}"
        else
            for i in $(seq 60 -2 2); do
                if deploy_ready "$client_id" "$ns"; then
                    printf "\r\033[K"
                    log_info "${BOLD}${client_id}${NC} (${ns}): ${GREEN}Ready${NC}"
                    break
                fi
                if [ "$i" -le 2 ]; then
                    printf "\r\033[K"
                    log_warn "${client_id} (${ns}): not Ready after 60s"
                    break
                fi
                countdown_tick "$i" 60 "Waiting for ${client_id}"
                sleep 2
            done
        fi
    done
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "  ${BOLD}${CYAN}━━ Agent Deployments${NC}"
for group in "${!AGENT_GROUPS[@]}"; do
    ns="${GROUP_NS[$group]}"
    echo "  ${group}:"
    for client_id in ${AGENT_GROUPS[$group]}; do
        PHASE=$(oc_w get pods -n "$ns" -l "agent-id=${client_id}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
        echo "    ${client_id}: ${PHASE}"
    done
done
echo ""
log_detail "Agents boot idle — they send no traffic until started."
echo ""
echo "  Next:  ./provision-console.sh --workload-context ${WORKLOAD_CTX}"
echo ""
echo "  To run guided demo:  ./run-demo.sh --maas-context ... --workload-context ${WORKLOAD_CTX}"
echo "  To start agents:     ./start-agents.sh --workload-context ${WORKLOAD_CTX}"
echo "  To stop agents:      ./stop-agents.sh --workload-context ${WORKLOAD_CTX}"
