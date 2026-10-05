#!/usr/bin/env bash
# Deploy the agent console on the Workload cluster.
#
# The console serves a small web UI and proxies to each agent's control API over
# cluster DNS, so start/stop/status needs one Route instead of N port-forwards.
#
# Safe to re-run: re-applies the ConfigMaps and rolls the pod when they change.
#
# Usage:
#   ./provision-console.sh --workload-context <ctx>
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared.sh
source "${DIR}/shared.sh"

WORKLOAD_CTX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --workload-context) WORKLOAD_CTX="$2"; shift 2 ;;
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

file_hash() {
    python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$1"
}
CONSOLE_HASH=$(file_hash "${DIR}/console/console.py")$(file_hash "${DIR}/console/index.html")

# =============================================================================
# Step 1: Build the agent registry the console proxies to
# =============================================================================
log_step 1 "Building agent registry"

AGENTS_JSON=$(
    for agent_id in $AGENT_IDS; do
        echo "${agent_id} $(agent_group "$agent_id") $(agent_ns "$agent_id")"
    done | python3 -c "
import json, sys
port = ${AGENT_CONTROL_PORT}
agents = []
for line in sys.stdin:
    aid, group, ns = line.split()
    agents.append({
        'id': aid,
        'group': group,
        'namespace': ns,
        'url': f'http://{aid}.{ns}.svc:{port}',
    })
print(json.dumps(agents))
"
)
log_info "Registry: $(echo "$AGENTS_JSON" | python3 -c 'import json,sys; print(", ".join(a["id"] for a in json.load(sys.stdin)))')"

# =============================================================================
# Step 2: Namespace and ConfigMaps
# =============================================================================
log_step 2 "Creating console namespace and ConfigMaps"

oc_w new-project "$CONSOLE_NS" > /dev/null 2>&1 || true
oc_w label namespace "$CONSOLE_NS" demo=cross-cluster-oauth --overwrite > /dev/null 2>&1 || true
log_info "Namespace: $CONSOLE_NS"

oc_w create configmap console-src -n "$CONSOLE_NS" \
    --from-file=console.py="${DIR}/console/console.py" \
    --from-file=index.html="${DIR}/console/index.html" \
    --dry-run=client -o yaml | oc_w apply -f - > /dev/null
log_info "ConfigMap console-src applied"

# =============================================================================
# Step 3: Deployment, Service, Route
# =============================================================================
log_step 3 "Deploying console"

cat <<EOF | oc_w apply -f - > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-console
  namespace: ${CONSOLE_NS}
  labels:
    app: agent-console
    demo: cross-cluster-oauth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agent-console
  template:
    metadata:
      annotations:
        console-src-hash: "${CONSOLE_HASH}"
      labels:
        app: agent-console
        demo: cross-cluster-oauth
    spec:
      containers:
        - name: console
          image: registry.access.redhat.com/ubi9/python-39:latest
          command: ["python3", "/opt/console/console.py"]
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PORT
              value: "8080"
            - name: STATIC_DIR
              value: "/opt/console"
            - name: AGENTS
              value: '${AGENTS_JSON}'
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 10
            periodSeconds: 20
          volumeMounts:
            - name: console-src
              mountPath: /opt/console
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: console-src
          configMap:
            name: console-src
---
apiVersion: v1
kind: Service
metadata:
  name: agent-console
  namespace: ${CONSOLE_NS}
  labels:
    app: agent-console
    demo: cross-cluster-oauth
spec:
  selector:
    app: agent-console
  ports:
    - name: http
      port: 8080
      targetPort: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: agent-console
  namespace: ${CONSOLE_NS}
  labels:
    app: agent-console
    demo: cross-cluster-oauth
spec:
  to:
    kind: Service
    name: agent-console
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
log_info "Deployment, Service and Route applied"

# =============================================================================
# Step 4: Wait for readiness
# =============================================================================
log_step 4 "Waiting for console to become ready"

READY=false
for i in $(seq 60 -2 2); do
    R=$(oc_w get deployment agent-console -n "$CONSOLE_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${R:-0}" -ge 1 ]; then
        printf "\r\033[K"
        READY=true
        break
    fi
    countdown_tick "$i" 60 "Waiting for agent-console"
    sleep 2
done
printf "\r\033[K"

CONSOLE_URL=$(console_url "$WORKLOAD_CTX")

if [ "$READY" = true ]; then
    log_info "Console ${GREEN}Ready${NC}"
else
    log_warn "Console not Ready after 60s — check: oc logs -n ${CONSOLE_NS} deploy/agent-console"
fi

echo ""
echo -e "  ${BOLD}${CYAN}━━ Agent Console${NC}"
if [ -n "$CONSOLE_URL" ]; then
    echo -e "  ${BOLD}${D_PINK}${CONSOLE_URL}${NC}"
    echo ""
    log_detail "The Route is unauthenticated — anyone who can reach it can start/stop agents."
    log_detail "Agent credentials never leave the pods; only traffic control is exposed."
else
    log_warn "Route not found — is this an OpenShift cluster?"
fi
echo ""
echo "  CLI equivalents:"
echo "    ./start-agents.sh  --workload-context ${WORKLOAD_CTX} [--cycles N]"
echo "    ./stop-agents.sh   --workload-context ${WORKLOAD_CTX}"
echo "    ./follow-agents.sh --workload-context ${WORKLOAD_CTX}"
echo ""
