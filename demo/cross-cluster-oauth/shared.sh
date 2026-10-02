#!/usr/bin/env bash
# Shared colors, logging, spinner, and Keycloak helpers for cross-cluster-oauth scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

# ── Colors ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
ORANGE='\033[0;91m'
BRIGHT_GREEN='\033[0;92m'
BRIGHT_RED='\033[0;91m'
PINK='\033[0;95m'
# Dracula theme palette (256-color)
D_CYAN='\033[38;5;117m'    # #8BE9FD
D_GREEN='\033[38;5;84m'    # #50FA7B
D_ORANGE='\033[38;5;215m'  # #FFB86C
D_PINK='\033[38;5;212m'    # #FF79C6
D_PURPLE='\033[38;5;141m'  # #BD93F9
D_RED='\033[38;5;203m'     # #FF5555
D_YELLOW='\033[38;5;228m'  # #F1FA8C
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()    { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
log_error()   { echo -e "  ${RED}✗${NC} $*"; }
log_detail()  { echo -e "  ${DIM}$*${NC}"; }

log_step() {
    local step="$1"; shift
    echo ""
    echo -e "  ${BOLD}${CYAN}━━ Step ${step}${NC} ${BOLD}$*${NC}"
}

log_section() {
    echo ""
    echo -e "  ${DIM}${BLUE}─────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${BLUE}$*${NC}"
    echo -e "  ${DIM}${BLUE}─────────────────────────────────────────────${NC}"
}

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""

spin() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
        printf "\r  ${DIM}${frames[$i]} %s${NC}" "$msg"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
}

start_spinner() {
    spin "$1" &
    SPINNER_PID=$!
}

stop_spinner() {
    [ -n "$SPINNER_PID" ] || return 0
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K"
    SPINNER_PID=""
}

# Kill any running spinner on script exit (covers crashes, Ctrl-C, early exit)
trap 'stop_spinner' EXIT

# Show a spinning countdown: countdown_tick <current_second> <total_seconds> <label>
# Call once per second inside a loop. Clears line on its own.
# Usage: for i in $(seq $total -1 1); do ...; countdown_tick "$i" "$total" "label"; done; printf "\r\033[K"
countdown_tick() {
    local i="$1" total="$2" label="$3"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local f=$(( (total - i) % ${#frames[@]} ))
    printf "\r  ${DIM}${frames[$f]} %s... %3ds${NC}" "$label" "$i"
}

# ── Keycloak ──────────────────────────────────────────────────────────────────

# Find a Keycloak instance on a cluster using the Keycloak CR.
# Sets globals KC_URL and KC_NS.
# Usage: keycloak_discover <oc-context>
keycloak_discover() {
    local ctx="$1"
    KC_NS=$(oc --context="$ctx" get keycloak -A \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    KC_URL=""
    if [ -n "$KC_NS" ]; then
        local host
        host=$(oc --context="$ctx" get route -n "$KC_NS" \
            -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
        [ -n "$host" ] && KC_URL="https://${host}"
    fi
}

# Get a Keycloak admin token. Tries RHBK and RHSSO secret locations.
# Prints the token to stdout; prints error to stderr and returns 1 on failure.
# Usage: keycloak_admin_token <keycloak-url> <keycloak-ns> <oc-context>
keycloak_admin_token() {
    local url="$1" ns="$2" ctx="$3"
    local admin_user="admin" admin_password=""

    # RHBK operator: keycloak-initial-admin secret
    admin_password=$(oc --context="$ctx" get secret keycloak-initial-admin -n "$ns" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    if [ -n "$admin_password" ]; then
        admin_user=$(oc --context="$ctx" get secret keycloak-initial-admin -n "$ns" \
            -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "admin")
    fi

    # RHSSO operator: credential-keycloak secret
    if [ -z "$admin_password" ]; then
        admin_password=$(oc --context="$ctx" get secret credential-keycloak -n "$ns" \
            -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo "")
        if [ -n "$admin_password" ]; then
            admin_user=$(oc --context="$ctx" get secret credential-keycloak -n "$ns" \
                -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null | base64 -d || echo "admin")
        fi
    fi

    if [ -z "$admin_password" ]; then
        echo "Keycloak admin credentials not found in namespace ${ns}" >&2
        return 1
    fi

    local response token
    response=$(curl -sSk -X POST "${url}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" -d "client_id=admin-cli" \
        -d "username=${admin_user}" -d "password=${admin_password}")
    token=$(echo "$response" | python3 -c "
import sys,json
d=json.load(sys.stdin)
t=d.get('access_token','')
if not t: raise SystemExit(d.get('error_description', d.get('error','no token')))
print(t)" 2>/dev/null || echo "")

    if [ -z "$token" ]; then
        echo "Failed to get Keycloak admin token from ${url}" >&2
        return 1
    fi
    echo "$token"
}
