# Cross-Cluster Agentic Access Demo

AI agent workloads running on a **Workload cluster** authenticate to MaaS on a separate **MaaS cluster** via Keycloak's OAuth2 client-credentials flow.

## Architecture

- **Dedicated AITenant** (`agents`) with its own Gateway and OIDC configuration
- **Dedicated Keycloak realm** (`agent-realm`) with per-agent clients and group-based categorization
- **3 agent categories**: chatbots, code-reviewers, business-analysts — each with its own behavior profile
- **Group-level MaaS subscriptions** with per-agent overrides via priority
- Fully isolated from the default tenant and other demos

## Prerequisites

- Two OpenShift clusters with `oc` contexts configured
- MaaS cluster: RHOAI with MaaS operator, Keycloak deployed (namespace `maas-keycloak`)
- A served model (e.g. `facebook-opt-125m-simulated`) available in the `llm` namespace
- `oc` CLI authenticated to both clusters

## Quick Start

```bash
# Interactive setup — asks for cluster contexts, provisions everything
./setup-demo.sh

# Run the demo walkthrough (token minting, JWT inspection, inference calls)
./run-demo.sh --maas-context <ctx> --workload-context <ctx>

# Open the agent console (start/stop toggles + live counters)
oc --context <ctx> get route agent-console -n agents-console -o jsonpath='{.spec.host}'

# ...or drive the same API from the CLI
./start-agents.sh  --workload-context <ctx> [--cycles N]
./follow-agents.sh --workload-context <ctx>
./stop-agents.sh   --workload-context <ctx>

# Clean up
./teardown-agents.sh --workload-context <ctx>
./cleanup-demo.sh --maas-context <ctx>
```

## Controlling the agents

Agent pods run permanently and sit **idle** until told to work. Traffic is started and
stopped by flipping a signal over each agent's control API — no pod restart, so all agents
begin at the same instant, the Keycloak JWT and MaaS API key are minted once at boot, and
counters survive a stop/start.

The `agent-console` Deployment serves a web UI and proxies to every agent over cluster DNS,
so no `oc port-forward` is needed:

| Endpoint | Purpose |
|----------|---------|
| `GET /api/status` | Per-agent and aggregate counters — requests, tokens, 2xx vs 4xx/5xx, uptime |
| `POST /api/start` | Start all agents; body `{"cycles": N, "reset": bool}` |
| `POST /api/stop` | Stop all agents |
| `POST /api/reset` | Zero all counters |
| `POST /api/agents/<id>/{start,stop,reset}` | Same, for one agent |

The UI polls `/api/status` every 2s and colours each agent by group, matching the colours
`follow-agents.sh` uses in the log tail.

> The console Route is **unauthenticated** — anyone who can reach it can start and stop
> agents. Agent credentials never leave the agent pods; only traffic control is exposed.

Counters are in-memory per pod, so they reset if a pod restarts — the `uptime` column
is there to explain a number that drops unexpectedly.

## Scripts

| Script | Purpose |
|--------|---------|
| `setup-demo.sh` | Interactive setup — calls provision-infra + provision-agents + provision-console + readiness-check |
| `provision-infra.sh` | Creates Gateway, AITenant, Keycloak realm, MaaS subscriptions on MaaS cluster |
| `provision-agents.sh` | Deploys agent pods (idle) and their control Services on Workload cluster |
| `provision-console.sh` | Deploys the agent console (UI + proxy) and its Route |
| `readiness-check.sh` | Validates all resources are in place and healthy |
| `check-gateway-wasm.sh` | Live gateway probe — catches the Kuadrant wasm fail-closed 503; `--fix` restarts the gateway |
| `run-demo.sh` | CLI walkthrough: token flow, JWT claims, inference calls, subscription priority |
| `start-agents.sh` | Starts agent traffic via the console API |
| `stop-agents.sh` | Stops agent traffic; pods stay up and counters are kept |
| `follow-agents.sh` | Tails all agent logs, colour-coded per group (read-only) |
| `cleanup-demo.sh` | Removes all demo resources from MaaS cluster |
| `teardown-agents.sh` | Deletes agent and console namespaces from Workload cluster |

## Agent Categories

| Group | Agents | Pattern | Rate Limit |
|-------|--------|---------|------------|
| chatbots | chatbot-1, chatbot-2 | conversational (one-at-a-time) | 500 tokens/min |
| code-reviewers | reviewer-1, reviewer-2 | burst (batch then pause) | 200 tokens/min |
| business-analysts | analyst-1 | periodic (rapid burst, long pause) | 300 tokens/min |

`chatbot-2` has a per-agent override at 2000 tokens/min via the `agents-chatbot-2-premium`
subscription (priority 50 > group priority 35).

## Directory Structure

```
cross-cluster-oauth/
├── setup-demo.sh
├── provision-infra.sh
├── provision-agents.sh
├── provision-console.sh
├── readiness-check.sh
├── check-gateway-wasm.sh     # standalone + sourced by readiness-check.sh
├── run-demo.sh
├── start-agents.sh
├── stop-agents.sh
├── follow-agents.sh
├── cleanup-demo.sh
├── teardown-agents.sh
├── shared.sh                 # colours, logging, agent topology, console helpers
├── manifests/
│   ├── gateway.yaml.tmpl
│   ├── aitenant.yaml.tmpl
│   ├── modelref.yaml
│   └── subscriptions.yaml
├── profiles/
│   ├── chatbot-profile.yaml
│   ├── reviewer-profile.yaml
│   └── analyst-profile.yaml
├── diagrams/
│   ├── 01-setup.drawio
│   └── 02-runtime-flow.drawio
├── agent/
│   └── agent.py              # traffic patterns + control API on :8080
└── console/
    ├── console.py            # UI server + per-agent proxy
    └── index.html
```

## Troubleshooting

**Everything returns HTTP 503 with an empty body**, while `Gateway` shows `Programmed=True`
and `AuthPolicy` shows `Enforced=True`. This is Kuadrant's Envoy wasm filter failing closed —
it is fetched over HTTP from the kuadrant-operator pod at startup, so any gateway pod that
boots while that operator is restarting locks into fail-closed mode permanently (Envoy never
re-fetches). Restarting the AuthPolicy or re-running provisioning will not help.

```bash
./check-gateway-wasm.sh --maas-context <ctx>          # diagnose
./check-gateway-wasm.sh --maas-context <ctx> --fix    # diagnose and restart the gateway
```

The probe sends several requests, not one: the failure is per-pod and the Gateway
load-balances, so a single request can land on a healthy pod and report all-clear. Confirm
with `oc logs <gateway-pod> -n openshift-ingress | grep wasm_fail_stream` — that string in
the access log is the reliable signal. Do **not** use `"failed to load"` from the startup
log; healthy pods emit it too for about a second while the async fetch is still in flight.
