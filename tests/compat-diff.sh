#!/usr/bin/env bash
# tests/compat-diff.sh — backward-compatibility proof.
#
# For representative env sets that use none of the new variables, renders the
# auto_enroll argv and the final config.yml twice: once with the functions
# from the original entrypoint ($1, e.g. `git show main:docker-entrypoint.sh`)
# and once with aer-lib.sh.  Each scenario simulates a first start followed by
# a restart, and the argv and both config files must be byte-identical.

# shellcheck disable=SC1090,SC2034  # dynamic sources; ZITI_VERSION is read by aer-lib.sh
set -eo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OLD_ENTRYPOINT="${1:?usage: compat-diff.sh OLD_ENTRYPOINT [OUT_DIR]}"
OUT_DIR="${2:-$(mktemp -d)}"
mkdir -p "${OUT_DIR}"

# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# Pull the v2.0 implementations out of the old entrypoint.  The enroll binary
# is replaced by a stub that records argv, and the hard-coded config path is
# pointed at the test file.
extract() { awk -v f="$1() {" '$0 == f {p = 1} p {print} p && /^}$/ {exit}' "${OLD_ENTRYPOINT}"; }
OLD_FUNCS="${WORK}/old-funcs.sh"
{
    extract FX_register_router
    extract SUBFX_dns_update_config_yaml
} | sed -e 's#/ziti_router_auto_enroll#old_enroll_stub#' \
        -e 's#local config_file="/etc/netfoundry/config.yml"#local config_file="${AER_CONFIG_FILE}"#' \
        -e 's#mkdir -p /etc/netfoundry/certs#:#' > "${OLD_FUNCS}"
old_enroll_stub() { OLD_ARGV=("$@"); }

SCENARIOS=(
    "auto, compose defaults|TUNNEL_MODE=auto ZITI_DNS_CONFIGURE=true"
    "auto, explicit DNS + advertise|TUNNEL_MODE=auto ZITI_DNS_CONFIGURE=true ZITI_DNS_UPSTREAM=udp://10.20.30.1:53 ZITI_DNS_RANGE=100.65.0.0/24 ADVERTISE_ADDRESS=203.0.113.10:443"
    "auto, tcp upstream + proxy|TUNNEL_MODE=auto ZITI_DNS_UPSTREAM=tcp://9.9.9.9:53 HTTPS_PROXY=http://proxy.corp.example.com:3128"
    "auto, DNS configure off|TUNNEL_MODE=auto ZITI_DNS_CONFIGURE=false ZITI_DNS_UPSTREAM=udp://1.1.1.1:53"
    "host, explicit|TUNNEL_MODE=host ZITI_DNS_CONFIGURE=true"
    "host, unset TUNNEL_MODE|ZITI_DNS_CONFIGURE=true"
    "host, pinned + advertise|TUNNEL_MODE=host ZITI_VERSION_OVERRIDE=v1.7.2 ADVERTISE_ADDRESS=edge.example.com:443"
)

rc=0
for spec in "${SCENARIOS[@]}"; do
    name="${spec%%|*}"
    slug=$(echo "${name}" | tr -c 'a-zA-Z0-9\n' '-')

    # --- before: original entrypoint functions ------------------------------
    reset_env
    env_args=()
    read -r -a env_args <<< "${spec#*|}"
    export "${env_args[@]}"
    (
        source "${AER_LIB}"   # logging only; old functions below override the rest
        stub_detect
        source "${OLD_FUNCS}"
        FX_register_router >/dev/null 2>&1
        printf '%s\n' "${OLD_ARGV[@]}" > "${OUT_DIR}/${slug}.argv.before"
        print_config "${OLD_ARGV[@]}"
        # v2.0: DNS patches only when TUNNEL_MODE=auto and DNS configure on
        for start in 1 2; do
            if [[ "${TUNNEL_MODE:-}" == "auto" && "${ZITI_DNS_CONFIGURE:-true}" != "false" ]]; then
                SUBFX_dns_update_config_yaml >/dev/null 2>&1
            fi
            cp "${AER_CONFIG_FILE}" "${OUT_DIR}/${slug}.start${start}.before.yml"
        done
    )

    # --- after: aer-lib.sh ---------------------------------------------------
    (
        source "${AER_LIB}"
        stub_detect
        ZITI_VERSION="v1.7.2"
        FX_validate_env >/dev/null 2>&1
        FX_build_enroll_args >/dev/null 2>&1
        printf '%s\n' "${AER_ENROLL_ARGS[@]}" > "${OUT_DIR}/${slug}.argv.after"
        print_config "${AER_ENROLL_ARGS[@]}"
        mkcert_from_config
        for start in 1 2; do
            FX_render_config > "${OUT_DIR}/${slug}.start${start}.after.log" 2>&1
            cp "${AER_CONFIG_FILE}" "${OUT_DIR}/${slug}.start${start}.after.yml"
        done
    )

    echo "== ${name}"
    echo "   env: ${spec#*|}"
    for pair in argv start1 start2; do
        if [[ "${pair}" == argv ]]; then
            a="${OUT_DIR}/${slug}.argv.before"; b="${OUT_DIR}/${slug}.argv.after"
        else
            a="${OUT_DIR}/${slug}.${pair}.before.yml"; b="${OUT_DIR}/${slug}.${pair}.after.yml"
        fi
        if diff -u "${a}" "${b}" > "${OUT_DIR}/${slug}.${pair}.diff"; then
            printf '   %-7s identical  (%s, sha256 %s)\n' "${pair}" \
                "$(wc -l < "${a}" | tr -d ' ') lines" "$(sha256sum < "${a}" | cut -c1-12)"
        else
            printf '   %-7s DIFFERS\n' "${pair}"
            sed 's/^/      /' "${OUT_DIR}/${slug}.${pair}.diff"
            rc=1
        fi
    done
done

echo
echo "Artifacts: ${OUT_DIR}"
[[ "${rc}" -eq 0 ]] && echo "Backward compatibility: all scenarios identical" || echo "Backward compatibility: DIFFERENCES FOUND"
exit "${rc}"
