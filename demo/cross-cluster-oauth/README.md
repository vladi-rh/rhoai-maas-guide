# Cross-Cluster Agentic Access Demo

AI agent workloads running on a **Workload cluster** authenticate to MaaS on a separate **MaaS cluster** via Keycloak's OAuth2 client-credentials flow.

## Architecture

- **Dedicated AITenant** (`agents`) with its own Gateway and OIDC configuration
- **Dedicated Keycloak realm** (`agent-realm`) with per-agent clients and group-based categorization
- **3 agent categories**: chatbots, code-reviewers, business-analysts — each with its own behavior profile
- **Group-level MaaS subscriptions** with per-agent overrides via priority
- Fully isolated from the default tenant and other demos

See [analysis.md](analysis.md) for the full problem statement, options evaluation, and recommendation.

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

# Start autonomous agent traffic
./start-agents.sh --workload-context <ctx>

# Clean up
./teardown-agents.sh --workload-context <ctx>
./cleanup-demo.sh --maas-context <ctx>
```

## Scripts

| Script | Purpose |
|--------|---------|
| `setup-demo.sh` | Interactive setup — calls provision-infra + provision-agents + readiness-check |
| `provision-infra.sh` | Creates Gateway, AITenant, Keycloak realm, MaaS subscriptions on MaaS cluster |
| `provision-agents.sh` | Deploys agent pods on Workload cluster |
| `readiness-check.sh` | Validates all resources are in place and healthy |
| `run-demo.sh` | CLI walkthrough: token flow, JWT claims, inference calls, subscription priority |
| `start-agents.sh` | Flips the start signal — agents begin sending inference requests |
| `cleanup-demo.sh` | Removes all demo resources from MaaS cluster |
| `teardown-agents.sh` | Deletes agent namespaces from Workload cluster |

## Agent Categories

| Group | Agents | Pattern | Rate Limit |
|-------|--------|---------|------------|
| chatbots | chatbot-1, chatbot-2 | conversational (one-at-a-time) | 500 tokens/min |
| code-reviewers | reviewer-1, reviewer-2 | burst (batch then pause) | 200 tokens/min |
| business-analysts | analyst-1 | periodic (rapid burst, long pause) | 300 tokens/min |

`chatbot-2` has a per-agent override at 2000 tokens/min (priority 50 > group priority 30).

## Directory Structure

```
cross-cluster-oauth/
├── setup-demo.sh
├── provision-infra.sh
├── provision-agents.sh
├── readiness-check.sh
├── run-demo.sh
├── start-agents.sh
├── cleanup-demo.sh
├── teardown-agents.sh
├── analysis.md
├── manifests/
│   ├── gateway.yaml.tmpl
│   ├── aitenant.yaml.tmpl
│   ├── modelref.yaml
│   └── subscriptions.yaml
├── profiles/
│   ├── chatbot-profile.yaml
│   ├── reviewer-profile.yaml
│   └── analyst-profile.yaml
└── agent/
    └── agent.py
```
