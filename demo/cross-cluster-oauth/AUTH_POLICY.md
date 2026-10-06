# AuthPolicy Patching: Challenge and Workaround

## The Problem

### How MaaS auth normally works

In the standard MaaS pattern, a single OIDC client (e.g. `maas-agents`) is configured in the
AITenant's `spec.oidc.clientId`. All users authenticate through this shared client — their
tokens all carry `azp: "maas-agents"`. The MaaS operator generates an AuthPolicy rule called
**`oidc-client-bound`** that enforces `azp == spec.oidc.clientId`. This is a security guard:
it ensures that only tokens issued for *this specific MaaS gateway* are accepted, rejecting
tokens minted for a different application that happen to share the same Keycloak realm.

### Why per-agent clients break this

This demo gives each AI agent its own Keycloak confidential client (`chatbot-1`, `reviewer-1`,
etc.) so that each agent has an individually revocable identity — one agent can be deprovisioned
without affecting others. The agents use `client_credentials` grant (no human user involved),
and each agent's JWT carries `azp: "<its-own-client-id>"` (e.g. `azp: "chatbot-1"`).

The `oidc-client-bound` rule checks `azp == "maas-agents"` and rejects every per-agent token
because their `azp` is the agent's own client ID, not the shared one. The rule therefore cannot
stay in its operator-generated form — but it must be **narrowed, not deleted**.

> **Correction.** An earlier version of this document argued the rule was redundant because
> "the audience claim (`aud`) already contains `maas-agents` via Keycloak's audience mapper,
> which is sufficient to prove the token is intended for this gateway." That is wrong on two
> counts, both verified against the live policy and realm:
>
> 1. **`aud` is never validated.** The `oidc-identities` authentication block sets only
>    `issuerUrl` and `ttl` — there is no `audiences` key, so the audience claim is not checked
>    at all.
> 2. **`aud` could not distinguish clients even if it were checked.** The audience mapper sits
>    on the realm's default `roles` scope, so *every* client in `agent-realm` receives
>    `aud: maas-agents`.
>
> Deleting the rule left `azp` unchecked entirely, meaning any client in the realm — including
> one created later for an unrelated purpose — satisfied it. The fix is an allowlist.

## The Workaround: Three-Part AuthPolicy Patch

### Part 1: Narrow `oidc-client-bound` to an allowlist

Annotate the AuthPolicy as `opendatahub.io/managed=false` to prevent the MaaS operator from
restoring its single-client rule, then replace the rule with a regex allowlist of the agent
clients. `provision-infra.sh` (Step 5b) does this automatically and builds the regex from its
own `GROUP_CLIENTS` map so it cannot drift; the shape it applies is:

```yaml
oidc-client-bound:
  metrics: false
  priority: 1
  when:                       # byte-identical to the operator's own predicate
  - predicate: '!request.headers.authorization.startsWith("Bearer sk-oai-") && ...'
  patternMatching:
    patterns:
    - selector: auth.identity.azp
      operator: matches       # operator generates `eq` with a single value
      value: ^(chatbot-1|chatbot-2|reviewer-1|reviewer-2|analyst-1)$
```

Applied with JSON-patch `add` rather than `replace`, so it works whether the rule is currently
absent (clusters provisioned before this change) or present (fresh install, operator-generated).

### Part 1b: Remove `openshift-identities`

Without this, any OpenShift token — including a zero-RBAC ServiceAccount's — authenticates at
this gateway and is only stopped later by `maas-api`, which returns `400 invalid_subscription`.
That match is on the bare group-name string regardless of which identity provider asserted it,
so an OpenShift Group coincidentally named e.g. `chatbots` would grant mint rights.

```bash
oc patch authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    --type=json -p='[{"op":"remove","path":"/spec/defaults/rules/authentication/openshift-identities"}]'
```

**Agents gateway only.** The default gateway's corporate demo depends on OpenShift identities
(`corp-*` and `maas-demo-users` subscriptions). The trade-off here is that `oc whoami -t` can no
longer be used to poke the agents gateway by hand.

### Part 2: Populate `model_access` (the hidden consequence)

Setting `managed=false` has a **side effect**: the MaaS operator also stops processing
`MaaSAuthPolicy` resources for this gateway. Normally, the operator reads MaaSAuthPolicy CRs
and populates the `model_access` map inside the `require-group-membership` OPA rego — this map
controls which groups/users can access which models.

With `managed=false`, this map stays empty:

```rego
model_access := {}   # <-- no group-to-model mappings
```

The result: every inference request is denied with 403 `PERMISSION_DENIED`, while API key
minting (which has no model identity) succeeds. The OPA rego logic:

1. Extracts `model_identity` from the URL path (e.g. `llm/facebook-opt-125m-simulated`)
2. Looks up `model_identity` in `model_access` — finds `null` (empty map)
3. Falls through all `allow` rules → **deny**

The fix: manually populate `model_access` after opting out of operator management:

```bash
# Extract current rego, replace empty model_access, patch back
CURRENT_REGO=$(oc get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    -o jsonpath='{.spec.defaults.rules.authorization.require-group-membership.opa.rego}')

# Replace model_access := {} with populated version
NEW_REGO=$(python3 -c "
import json, sys
rego = sys.stdin.read()
access = {'llm/facebook-opt-125m-simulated': {
    'groups': ['chatbots', 'code-reviewers', 'business-analysts'],
    'users': []
}}
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

oc patch authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    --type=json -p="$PATCH_JSON"
```

## How to Verify

The `model_access` key is `<model-namespace>/<model-name>` — derived from the URL path
structure that MaaS uses for inference routing (`/llm/facebook-opt-125m-simulated/v1/...`).

```bash
# Should show populated model_access, not {}
oc get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress \
    -o jsonpath='{.spec.defaults.rules.authorization.require-group-membership.opa.rego}' \
    | head -10

# Policy shape: expect authn WITHOUT openshift-identities, and an azp rule using `matches`
oc get authpolicy agents-maas-gateway-maas-auth -n openshift-ingress -o json \
  | python3 -c "import json,sys; s=json.load(sys.stdin)['spec']; s=s.get('defaults',s); \
      print('authn:', list(s['rules']['authentication'])); \
      print('azp  :', s['rules']['authorization'].get('oidc-client-bound',{}).get('patternMatching'))"
```

`readiness-check.sh` asserts all three automatically.

## MaaSAuthPolicy Status

With `managed=false`, MaaSAuthPolicy resources will remain in `Pending` phase with:

```
Waiting for gateway AuthPolicy ... to be accepted and enforced:
AuthPolicy is opted out of controller management
```

This is expected. The MaaSAuthPolicy CRs still serve as documentation of intended access, but
the actual enforcement is handled by the manually populated `model_access` map.

## When Is This Needed?

Only when using per-agent OIDC clients (each agent authenticates with its own `client_id`)
rather than a single shared client. The standard MaaS pattern uses one OIDC client where
`azp == spec.oidc.clientId`, making `oidc-client-bound` valid. The per-agent pattern trades
that simplicity for individually revocable agent identities.

## Scripts

- `provision-infra.sh` — step 5b applies all three parts automatically, and is idempotent, so
  re-running it is the supported way to re-assert the policy after a drift or a reversion
- `readiness-check.sh` — asserts the resulting shape (allowlist present and correct,
  `openshift-identities` absent, `model_access` populated)

To hand back control to the operator, remove the `opendatahub.io/managed=false` annotation; it
will restore its own single-client `oidc-client-bound` and reset `model_access`, which 403s the
fleet. Every patch here survives only while that annotation is set.
