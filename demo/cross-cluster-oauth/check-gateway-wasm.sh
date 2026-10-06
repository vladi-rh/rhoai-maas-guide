#!/usr/bin/env bash
# Probe a Kuadrant-managed Gateway for the "wasm shim failed to load" failure mode.
#
# Kuadrant serves its Envoy wasm filter over plain HTTP from the operator pod itself
# (kuadrant-operator-wasm.openshift-operators.svc:8082/plugin.wasm). A gateway pod that
# starts while that operator is down exhausts Envoy's fetch retries and locks itself into
# fail-closed mode for its whole lifetime — Envoy never re-fetches after boot.
#
# Every resource status stays green in that state: Gateway reports Programmed=True and
# AuthPolicy reports Enforced=True, while the gateway 503s every single request. The only
# reliable signal is a live HTTP request — a working gateway rejects a bad token with
# 401/403, a broken one answers 503.
#
# Fix: restart the gateway Deployment so Envoy re-fetches the binary. Never the AuthPolicy
# — it stays Accepted/Enforced throughout and is not the cause.
#
# Usage:
#   ./check-gateway-wasm.sh --maas-context <ctx> [--gateway <name>] [--fix]
#     --gateway <name>  default agents-maas-gateway; use maas-default-gateway for the main one
#     --fix             restart the gateway Deployment if the probe fails, then re-probe
#
# Exit codes: 0 healthy, 1 broken, 2 inconclusive.
#
# Also sourceable — readiness-check.sh sources this file and calls check_gateway_wasm so
# the results fold into its own pass/fail tally.

GATEWAY_NS="openshift-ingress"
# Any authenticated route works; a bad token must never mint anything, only be rejected.
GATEWAY_PROBE_PATH="/maas-api/v1/api-keys"

# Colours/logging come from shared.sh. Guarded so sourcing twice is harmless.
if [ -z "${NC:-}" ]; then
    # shellcheck source=shared.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared.sh"
fi

# Standalone fallbacks. When sourced from readiness-check.sh its own counting versions
# already exist and are left untouched, so PASS/FAIL/WARN keep incrementing there.
declare -F check_pass >/dev/null 2>&1 || check_pass() { echo -e "    ${GREEN}✓${NC} $*"; }
declare -F check_fail >/dev/null 2>&1 || check_fail() { echo -e "    ${RED}✗${NC} $*"; }
declare -F check_warn >/dev/null 2>&1 || check_warn() { echo -e "    ${YELLOW}⚠${NC} $*"; }

# One real request with a deliberately invalid token. Prints the HTTP status, 000 on timeout.
gateway_probe() {
    local host="$1"
    curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
        -X POST "https://${host}${GATEWAY_PROBE_PATH}" \
        -H "Authorization: Bearer gateway-liveness-probe-invalid-token" \
        -H "Content-Type: application/json" \
        -d '{"name":"gateway-liveness-probe","expiresIn":"60s"}' 2>/dev/null || echo "000"
}

# Probe repeatedly and print all status codes.
#
# A Gateway load-balances across its pods, and the wasm failure is per-pod: only the pods
# that booted during the operator outage are fail-closed. A single request can land on a
# healthy pod and report all-clear while half the fleet 503s, so probe ~3x the pod count.
gateway_probe_many() {
    local host="$1" attempts="$2" codes="" i
    for i in $(seq 1 "$attempts"); do
        codes="${codes}$(gateway_probe "$host") "
    done
    echo "$codes"
}

# Count wasm_fail_stream entries across the gateway's pods.
#
# Deliberately NOT matching "Plugin kuadrant-wasm-shim failed to load" — that line also
# appears for ~1s on healthy pods while the async fetch is still in flight, so it produces
# false positives. wasm_fail_stream only ever appears in the access log for a request that
# was actually failed closed.
gateway_wasm_failures() {
    local ctx="$1" gw="$2" total=0 n pod
    for pod in $(oc --context="$ctx" get pods -n "$GATEWAY_NS" \
            -l "gateway.networking.k8s.io/gateway-name=${gw}" -o name 2>/dev/null); do
        n=$(oc --context="$ctx" logs -n "$GATEWAY_NS" "$pod" --tail=200 2>/dev/null \
            | grep -c "wasm_fail_stream" || true)
        total=$(( total + ${n:-0} ))
    done
    echo "$total"
}

gateway_deployment() {
    oc --context="$1" get deploy -n "$GATEWAY_NS" \
        -l "gateway.networking.k8s.io/gateway-name=$2" -o name 2>/dev/null | head -1
}

# check_gateway_wasm <maas-context> [gateway-name] [fix:true|false]
check_gateway_wasm() {
    local ctx="$1" gw="${2:-agents-maas-gateway}" fix="${3:-false}"
    local host status fails deploy

    host=$(oc --context="$ctx" get gateway "$gw" -n "$GATEWAY_NS" \
        -o jsonpath='{.spec.listeners[?(@.name=="https")].hostname}' 2>/dev/null || echo "")
    if [ -z "$host" ]; then
        check_warn "Gateway ${gw}: hostname not resolvable — skipping liveness probe"
        return 2
    fi

    # Scale the probe count to the pod count so a partially-broken fleet can't hide.
    local pods attempts codes n_ok n_503 n_other
    pods=$(oc --context="$ctx" get pods -n "$GATEWAY_NS" \
        -l "gateway.networking.k8s.io/gateway-name=${gw}" -o name 2>/dev/null | wc -l | tr -d ' ')
    attempts=$(( ${pods:-1} * 3 ))
    [ "$attempts" -lt 4 ] && attempts=4

    codes=$(gateway_probe_many "$host" "$attempts")
    n_ok=$(printf '%s\n' $codes | grep -cE '^(401|403)$' || true)
    n_503=$(printf '%s\n' $codes | grep -c '^503$' || true)
    n_other=$(( attempts - ${n_ok:-0} - ${n_503:-0} ))
    status="${codes%% *}"

    if [ "${n_503:-0}" -gt 0 ]; then
        if [ "${n_ok:-0}" -gt 0 ]; then
            check_fail "Gateway ${gw}: ${n_503}/${attempts} probes returned 503 — SOME pods fail-closed"
            log_detail "    A subset of pods booted while kuadrant-operator was down; the rest are fine."
        else
            check_fail "Gateway ${gw}: ${n_503}/${attempts} probes returned 503 — kuadrant-wasm-shim failed to load"
            log_detail "    Cause: pods started while kuadrant-operator (which serves plugin.wasm) was down"
        fi
        if [ "$fix" != "true" ]; then
            deploy=$(gateway_deployment "$ctx" "$gw")
            log_detail "    Fix:   oc --context=${ctx} rollout restart ${deploy:-deploy/${gw}-openshift-default} -n ${GATEWAY_NS}"
            return 1
        fi
    elif [ "${n_ok:-0}" -eq "$attempts" ]; then
        check_pass "Gateway ${gw}: ${n_ok}/${attempts} probes HTTP 401/403 — auth enforced, wasm shim loaded"
    elif [ "${n_other:-0}" -eq "$attempts" ] && [ "$status" = "000" ]; then
        check_warn "Gateway ${gw}: no response (timeout or DNS) — check the Route and ingress"
        return 2
    else
        check_warn "Gateway ${gw}: mixed responses [${codes}] — not a known wasm failure"
        return 2
    fi

    # Secondary signal. Runs after the probe so the probe's own 503 is already in the log.
    fails=$(gateway_wasm_failures "$ctx" "$gw")
    if [ "${fails:-0}" -gt 0 ]; then
        check_fail "Gateway ${gw}: ${fails} wasm_fail_stream entries in recent pod logs"
        [ "$fix" != "true" ] && return 1
    else
        check_pass "Gateway ${gw}: no wasm_fail_stream entries in pod logs"
    fi

    # --fix: restart the Deployment so Envoy re-fetches the wasm binary, then re-probe.
    if [ "$fix" = "true" ] && { [ "$status" = "503" ] || [ "${fails:-0}" -gt 0 ]; }; then
        deploy=$(gateway_deployment "$ctx" "$gw")
        if [ -z "$deploy" ]; then
            check_fail "Gateway ${gw}: Deployment not found — cannot auto-fix"
            return 1
        fi
        # Precondition: the wasm binary must actually be served right now. Envoy fetches it
        # once at boot and never retries, so restarting while kuadrant-operator is down just
        # re-creates the same fail-closed state — the rollout "succeeds" and the gateway is
        # still broken. The Service loses its endpoints the moment the operator pod goes
        # unready, which is a cheap and exact readiness signal.
        #
        # After a cluster restart the operator crashloops for a while (reconcile storm pegs
        # its 200m CPU limit, the throttled process misses its 1s liveness probe, SIGKILL,
        # repeat), so this window is common rather than rare — wait it out.
        wasm_ready() {
            local ep
            ep=$(oc --context="$ctx" get endpoints kuadrant-operator-wasm \
                 -n openshift-operators -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
            [ -n "$ep" ]
        }
        if ! wasm_ready; then
            echo ""
            log_warn "kuadrant-operator-wasm has no endpoints — plugin.wasm is not being served."
            log_detail "    Restarting now would land in the same down-window. Waiting up to 5 min..."
            for i in $(seq 1 60); do
                sleep 5
                wasm_ready && break
            done
            if ! wasm_ready; then
                check_fail "Gateway ${gw}: not restarting — kuadrant-operator is still not serving plugin.wasm"
                log_detail "    The operator is likely crashlooping. Check it, then re-run with --fix:"
                log_detail "    oc --context=${ctx} get pods -n openshift-operators -l control-plane=controller-manager"
                return 1
            fi
            log_info "wasm endpoint is back — proceeding"
        fi

        echo ""
        log_info "Restarting ${deploy} to re-fetch the wasm binary..."
        oc --context="$ctx" rollout restart "$deploy" -n "$GATEWAY_NS" > /dev/null
        oc --context="$ctx" rollout status "$deploy" -n "$GATEWAY_NS" --timeout=180s > /dev/null \
            || { check_fail "Rollout did not complete in 180s"; return 1; }
        sleep 5
        status=$(gateway_probe "$host")
        if [ "$status" = "401" ] || [ "$status" = "403" ]; then
            check_pass "Gateway ${gw}: HTTP ${status} after restart — recovered"
            return 0
        fi
        check_fail "Gateway ${gw}: still HTTP ${status} after restart"
        log_detail "    Check the wasm endpoint is serving:"
        log_detail "    oc --context=${ctx} run wasmprobe -n openshift-operators --rm -i --restart=Never \\"
        log_detail "      --image=curlimages/curl:latest -- curl -s -o /dev/null -w '%{http_code}\\n' \\"
        log_detail "      http://kuadrant-operator-wasm.openshift-operators.svc.cluster.local:8082/plugin.wasm"
        return 1
    fi

    return 0
}

main() {
    local maas_ctx="" gateway="agents-maas-gateway" fix="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --maas-context) maas_ctx="$2"; shift 2 ;;
            --gateway)      gateway="$2";  shift 2 ;;
            --fix)          fix="true";    shift ;;
            -h|--help)
                sed -n '2,/^$/p' "$0" | sed 's/^# *//'
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [ -z "$maas_ctx" ]; then
        log_error "Required: --maas-context"
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}${CYAN}━━ Gateway liveness${NC} ${DIM}(${gateway})${NC}"
    check_gateway_wasm "$maas_ctx" "$gateway" "$fix"
    local rc=$?
    echo ""
    exit $rc
}

# Run only when executed directly; sourcing just defines the functions above.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    main "$@"
fi
