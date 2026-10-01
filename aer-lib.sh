#!/usr/bin/env bash
# aer-lib.sh — NetFoundry Autonomous Edge Router: validation + config rendering
#
# Copyright 2026 NetFoundry Inc.
# Licensed under the Apache License, Version 2.0
# https://www.apache.org/licenses/LICENSE-2.0
#
# Sourced by docker-entrypoint.sh and by tests/render-tests.sh.  Nothing in
# this file enrolls a router, starts ziti, or touches the host resolver, so the
# auto_enroll argv and the config.yml rendering can be exercised in isolation.

AER_CONFIG_FILE="${AER_CONFIG_FILE:-/etc/netfoundry/config.yml}"

############### Logging ###############

log()  { echo "[AER-LOG ] $*"; }
ok()   { echo "[AER-OK  ] $*"; }
warn() { echo "[AER-WARN] $*" >&2; }
err()  { echo "[AER-ERR ] $*" >&2; exit 1; }

############### Host detection ###############

SUBFX_dns_detect_lan_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
    if [[ -z "${ip}" ]]; then
        ip=$(ip -4 addr show scope global | awk '/inet / {split($2,a,"/"); print a[1]; exit}')
    fi
    echo "${ip}"
}

SUBFX_dns_detect_fallback() {
    local dns
    # /run/systemd/resolve/resolv.conf is written by systemd-resolved with the
    # actual upstream nameservers (not the 127.0.0.53 stub).  It is accessible
    # inside the container via the /run/systemd:/run/systemd volume mount and is
    # the most reliable source at container startup before Ziti configures DNS.
    dns=$(awk '/^nameserver/ && $2!~/^127\./ {print $2; exit}' \
        /run/systemd/resolve/resolv.conf 2>/dev/null)
    [[ -n "${dns}" ]] && { echo "${dns}"; return; }
    dns=$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    [[ -n "${dns}" ]] && { echo "${dns}"; return; }
    echo "1.1.1.1"
}

############### auto_enroll arguments ###############

# Builds AER_ENROLL_ARGS, the argv for /ziti_router_auto_enroll.
# Reads: zitiVersion, upgradelink, TUNNEL_MODE, HTTPS_PROXY, ADVERTISE_ADDRESS,
#        ZITI_VERSION_OVERRIDE
FX_build_enroll_args() {
    local main_ver dot_ver ctrl_port
    main_ver=$(awk -F '.' '{print $1}' <<< "${zitiVersion}")
    dot_ver=$(awk  -F '.' '{print $2}' <<< "${zitiVersion}")

    if [[ "${main_ver}" -lt 1 && "${dot_ver}" -lt 30 ]]; then
        ctrl_port="80"
    else
        ctrl_port="443"
    fi

    local proxy_args=""
    if [[ -n "${HTTPS_PROXY:-}" ]]; then
        local ptype paddr pport
        ptype=$(awk -F ':'   '{print $1}'     <<< "${HTTPS_PROXY}")
        paddr=$(awk -F '[:/@]+' '{print $2}'  <<< "${HTTPS_PROXY}")
        pport=$(awk -F ':'   '{print $NF}'    <<< "${HTTPS_PROXY}")
        proxy_args="--proxyType ${ptype} --proxyAddress ${paddr} --proxyPort ${pport}"
    fi

    local advertise_args=""
    if [[ -n "${ADVERTISE_ADDRESS:-}" ]]; then
        advertise_args="--edgeListeners tls:0.0.0.0:443 ${ADVERTISE_ADDRESS}"
    fi

    local tunnel_option="--tunnelListener host"
    if [[ "${TUNNEL_MODE:-}" == "auto" ]]; then
        tunnel_option="--autoTunnelListener"
    elif [[ -n "${TUNNEL_MODE:-host}" ]]; then
        log "TUNNEL_MODE '${TUNNEL_MODE}'; using host mode"
    else
        warn "Unknown TUNNEL_MODE '${TUNNEL_MODE}'; using host mode"
    fi

    # If a version pin is set, tell auto_enroll to download that version now so
    # the post-registration upgrade check finds the binary already correct and
    # skips a redundant second download.
    local version_args=""
    if [[ -n "${ZITI_VERSION_OVERRIDE:-}" ]]; then
        version_args="--installVersion ${ZITI_VERSION_OVERRIDE#v}"
        log "Passing --installVersion ${ZITI_VERSION_OVERRIDE#v} to auto_enroll"
    fi

    # The *_args strings are word-split on purpose, exactly as the original
    # inline command line was, so the resulting argv is unchanged.
    # shellcheck disable=SC2206
    AER_ENROLL_ARGS=(-n -j docker.jwt ${tunnel_option}
        --installDir /etc/netfoundry
        --controllerFabricPort "${ctrl_port}"
        ${proxy_args} ${advertise_args}
        --downloadUrl "${upgradelink}"
        ${version_args}
        --skipSystemd)
}

############### config.yml rendering ###############

SUBFX_dns_update_config_yaml() {
    local config_file="${AER_CONFIG_FILE}"
    if [[ ! -f "${config_file}" ]]; then
        warn "config.yml not found at ${config_file}; skipping YAML update"
        return
    fi

    if [[ -n "${ZITI_DNS_RANGE:-}" ]]; then
        log "Setting dnsSvcIpRange=${ZITI_DNS_RANGE} in config.yml"
        DNS_RANGE="${ZITI_DNS_RANGE}" \
            yq e '(.listeners[] | select(.binding == "tunnel") | .options.dnsSvcIpRange) = env(DNS_RANGE)' \
            -i "${config_file}"
        ok "dnsSvcIpRange set to ${ZITI_DNS_RANGE}"
    fi

    # dnsUpstream is always written — Ziti must know where to forward
    # non-overlay queries.  Auto-detect from host resolver when not set.
    local upstream="${ZITI_DNS_UPSTREAM:-}"
    if [[ -z "${upstream}" ]]; then
        local raw_ip
        raw_ip=$(SUBFX_dns_detect_fallback)
        upstream="udp://${raw_ip}:53"
        log "ZITI_DNS_UPSTREAM not set — auto-detected: ${upstream}"
    fi
    DNS_UPSTREAM="${upstream}" \
        yq e '(.listeners[] | select(.binding == "tunnel") | .options.dnsUpstream) = env(DNS_UPSTREAM)' \
        -i "${config_file}"
    ok "dnsUpstream set to ${upstream}"
}
