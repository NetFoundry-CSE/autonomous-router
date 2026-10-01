#!/usr/bin/env bash
# tests/lib.sh — shared helpers for the render tests.  Runs inside the AER
# image (needs /ziti_router_auto_enroll, yq, openssl).  Nothing here talks to
# a controller: enrollment is simulated with auto_enroll --printConfig and a
# throwaway self-signed server cert whose SANs mirror the rendered CSR.

# shellcheck disable=SC2034  # RC, OUT, ENROLL_ARGV etc. are read by the sourcing script
AER_LIB="${AER_LIB:-/aer-lib.sh}"
WORK=$(mktemp -d)
export AER_CONFIG_FILE="${WORK}/config.yml"
export AER_CERT_DIR="${WORK}/certs"
mkdir -p "${AER_CERT_DIR}"

# Unsigned JWT: auto_enroll only decodes it (no signature check) for --printConfig.
_b64() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
FAKE_JWT="${WORK}/fake.jwt"
echo "$(printf '{"alg":"RS256","typ":"JWT"}' | _b64).$(printf '{"iss":"https://ctrl.example.test:443","exp":4102444800,"sub":"test"}' | _b64).c2ln" > "${FAKE_JWT}"

# Every env var the AER reads; cleared before each case.
AER_ENV_VARS=(TUNNEL_MODE ZITI_DNS_CONFIGURE ZITI_DNS_UPSTREAM ZITI_DNS_UPSTREAM_MODE
    ZITI_DNS_RANGE ADVERTISE_ADDRESS HTTPS_PROXY ZITI_VERSION_OVERRIDE ZITI_VERSION
    ZITI_LINK_LISTENER_ENABLED ZITI_LINK_ADVERTISE ZITI_LINK_ADVERTISE_PORT
    ZITI_LINK_BIND ZITI_LINK_OUTQUEUESIZE)

reset_env() {
    unset "${AER_ENV_VARS[@]}"
    zitiVersion="1.7.2"
    upgradelink="https://downloads.example.test/ziti-linux-amd64.tar.gz"
}

# Deterministic host resolver for the "ZITI_DNS_UPSTREAM unset" path.
stub_detect() {
    SUBFX_dns_detect_fallback() { echo "10.20.30.1"; }
}

# Runs auto_enroll --printConfig with argv $@ (docker.jwt swapped for the
# fake JWT) and writes the result to AER_CONFIG_FILE.
print_config() {
    local args=("$@") i
    for i in "${!args[@]}"; do
        [[ "${args[$i]}" == "docker.jwt" ]] && args[$i]="${FAKE_JWT}"
    done
    /ziti_router_auto_enroll "${args[@]}" --printConfig > "${AER_CONFIG_FILE}" 2>/dev/null
}

# Issues certs/server_cert.pem with the given SAN list ("DNS:a,IP:1.2.3.4").
mkcert_sans() {
    rm -f "${AER_CERT_DIR}"/*.pem
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "${AER_CERT_DIR}/key.pem" -out "${AER_CERT_DIR}/server_cert.pem" \
        -subj "/CN=aer-test" -days 1 -addext "subjectAltName=$1" >/dev/null 2>&1
}

# Issues a cert whose SANs are exactly the rendered config's edge.csr.sans,
# i.e. what a real enrollment of that config would have produced.
mkcert_from_config() {
    local sans="" v
    for v in $(yq '.edge.csr.sans.dns // [] | .[]' "${AER_CONFIG_FILE}"); do sans+="DNS:${v},"; done
    for v in $(yq '.edge.csr.sans.ip // [] | .[]' "${AER_CONFIG_FILE}"); do sans+="IP:${v},"; done
    mkcert_sans "${sans%,}"
}

# Simulated first start: validate env, build argv, render the config with
# auto_enroll, issue the cert.  Sets ENROLL_ARGV (space-joined argv).
enroll() {
    FX_validate_env >/dev/null 2>&1
    FX_build_enroll_args >/dev/null 2>&1
    ENROLL_ARGV="${AER_ENROLL_ARGS[*]}"
    print_config "${AER_ENROLL_ARGS[@]}"
    mkcert_from_config
}

# Runs validate + render in a subshell.  Sets RC and OUT (stdout+stderr).
render() {
    set +e
    OUT=$( ( set -eo pipefail; FX_validate_env; FX_render_config ) 2>&1 )
    RC=$?
    set -e
}

# Runs only FX_validate_env in a subshell.  Sets RC and OUT.
validate() {
    set +e
    OUT=$( ( set -eo pipefail; FX_validate_env ) 2>&1 )
    RC=$?
    set -e
}

md5() { md5sum < "${AER_CONFIG_FILE}" | cut -c1-12; }
tunnel() { yq "[.listeners[] | select(.binding == \"tunnel\")] | .[0]$1" "${AER_CONFIG_FILE}"; }

############### Assertions ###############

PASS=0
FAIL=0
CASE=""

case_start() { CASE="$*"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf '  ok    %-28s %s\n' "${CASE}" "${desc}"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %-28s %s\n' "${CASE}" "${desc}"
        [[ -n "${OUT:-}" ]] && printf '        | %s\n' "${OUT//$'\n'/$'\n'        | }"
    fi
}

eq()       { [[ "$1" == "$2" ]] || { echo "expected '$2', got '$1'" >&2; return 1; }; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks()    { [[ "$1" != *"$2"* ]]; }

summary() {
    echo
    echo "Results: ${PASS} passed, ${FAIL} failed"
    rm -rf "${WORK}"
    [[ "${FAIL}" -eq 0 ]]
}
