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

# Interface carrying the default route, and its first IPv4 address.  These
# mirror auto_enroll's get_default_interface()/get_private_address(), which
# --autoTunnelListener uses for lanIf and the resolver address.
SUBFX_detect_default_iface() {
    ip route show default 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

SUBFX_detect_iface_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

############### Address + version helpers ###############

SUBFX_is_ipv4() {
    local octet
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        (( 10#${octet} <= 255 )) || return 1
    done
}

# Loose IPv6 check: hex digits, colons and dots, with at least two colons.
SUBFX_is_ipv6() {
    local colons="${1//[^:]/}"
    [[ "$1" =~ ^[0-9A-Fa-f:.]+$ && ${#colons} -ge 2 ]]
}

SUBFX_is_dns_name() {
    local name="${1%.}"
    local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    [[ -n "${name}" && ${#name} -le 253 ]] || return 1
    [[ "${name}" =~ ^${label}(\.${label})*$ ]] || return 1
    # All-numeric dotted strings are malformed IPv4 addresses, not names.
    [[ ! "${name}" =~ ^[0-9.]+$ ]]
}

SUBFX_is_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Normalises one dnsUpstream entry and prints it:
#   1.1.1.1 | dns.corp       -> udp://HOST:53
#   HOST:PORT                -> udp://HOST:PORT
#   2001:db8::1 | [v6]:PORT  -> udp://[v6]:53 | udp://[v6]:PORT
#   udp://... | tcp://...    -> unchanged
# On failure prints the reason and returns 1.
SUBFX_normalize_upstream() {
    local entry="$1" host port
    local re_scheme='^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$'
    local re_v6='^\[([^]]+)\](:([0-9]+))?$'
    local re_hostport='^([^:]+):([0-9]+)$'

    if [[ "${entry}" =~ ${re_scheme} ]]; then
        case "${BASH_REMATCH[1],,}" in
            udp|tcp)
                [[ -n "${BASH_REMATCH[2]}" ]] || { echo "missing host after scheme"; return 1; }
                echo "${BASH_REMATCH[1],,}://${BASH_REMATCH[2]}"
                return 0 ;;
            *)
                echo "unsupported scheme '${BASH_REMATCH[1]}://'"
                return 1 ;;
        esac
    elif [[ "${entry}" =~ ${re_v6} ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]:-53}"
        SUBFX_is_ipv6 "${host}" || { echo "'${host}' is not an IPv6 address"; return 1; }
        host="[${host}]"
    elif SUBFX_is_ipv6 "${entry}"; then
        host="[${entry}]"
        port=53
    elif [[ "${entry}" =~ ${re_hostport} ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${entry}"
        port=53
    fi

    if [[ "${host}" != \[* ]] && ! SUBFX_is_ipv4 "${host}" && ! SUBFX_is_dns_name "${host}"; then
        echo "'${host}' is not a valid IP address or hostname"
        return 1
    fi
    SUBFX_is_port "${port}" || { echo "port '${port}' is out of range 1-65535"; return 1; }
    echo "udp://${host}:${port}"
}

# Sets AER_DNS_UPSTREAMS from ZITI_DNS_UPSTREAM: comma and/or whitespace
# separated, normalised, de-duplicated with order preserved (order matters
# for the serial and failover query modes).
SUBFX_parse_upstreams() {
    AER_DNS_UPSTREAMS=()
    local -a raw=()
    local entry norm seen dup
    IFS=$', \t\n' read -r -d '' -a raw <<< "${ZITI_DNS_UPSTREAM:-}" || true

    for entry in "${raw[@]}"; do
        [[ -n "${entry}" ]] || continue
        norm=$(SUBFX_normalize_upstream "${entry}") \
            || err "ZITI_DNS_UPSTREAM entry '${entry}' is invalid (${norm}); allowed forms: IP, hostname, HOST:PORT, [IPv6]:PORT, udp://HOST:PORT, tcp://HOST:PORT"
        dup=false
        for seen in "${AER_DNS_UPSTREAMS[@]}"; do
            [[ "${seen}" == "${norm}" ]] && dup=true
        done
        [[ "${dup}" == "true" ]] || AER_DNS_UPSTREAMS+=("${norm}")
    done
}

# Parses a ziti version (v1.7.2, 2.1.0-pre2, ...) into AER_VER=(major minor
# patch).  Pre-release suffixes are ignored, so v2.1.0-pre2 counts as 2.1.0.
# Returns 1 when the version cannot be determined.
SUBFX_parse_version() {
    AER_VER=()
    [[ "${1:-}" =~ ^[[:space:]]*v?([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    AER_VER=("$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))")
}

# True when the parsed AER_VER is >= $1.$2.$3.
SUBFX_version_ge() {
    local want=("$1" "$2" "$3") i
    for i in 0 1 2; do
        (( AER_VER[i] > want[i] )) && return 0
        (( AER_VER[i] < want[i] )) && return 1
    done
    return 0
}

############### Environment validation ###############
# FX_validate_env runs on every start, before registration, so a bad value
# stops the container before anything is enrolled or rewritten.

# Sets AER_TUNNEL_MODE (auto|host|none) and _DNS_ACTIVE.
FX_validate_env() {
    local mode="${TUNNEL_MODE:-}"
    mode="${mode//[[:space:]]/}"
    mode="${mode,,}"
    case "${mode}" in
        "")             AER_TUNNEL_MODE="host" ;;
        auto|host|none) AER_TUNNEL_MODE="${mode}" ;;
        *) err "TUNNEL_MODE='${TUNNEL_MODE}' is invalid; allowed values: auto, host, none (case-insensitive, unset means host)" ;;
    esac

    # DNS management (config.yml DNS patches + systemd-resolved) requires
    # TUNNEL_MODE=auto.  In host mode Ziti does not open a DNS port, and in
    # none mode there is no tunnel binding at all.
    # ZITI_DNS_CONFIGURE=false can suppress DNS setup even when TUNNEL_MODE=auto.
    _DNS_ACTIVE=false
    if [[ "${AER_TUNNEL_MODE}" == "auto" && "${ZITI_DNS_CONFIGURE:-true}" != "false" ]]; then
        _DNS_ACTIVE=true
    fi

    # Parsed even when unused so a typo fails here, not after a mode change.
    SUBFX_parse_upstreams

    if [[ -n "${ZITI_DNS_UPSTREAM:-}" && "${_DNS_ACTIVE}" != "true" ]]; then
        if [[ "${AER_TUNNEL_MODE}" == "auto" ]]; then
            warn "ZITI_DNS_UPSTREAM is ignored: ZITI_DNS_CONFIGURE=false"
        else
            warn "ZITI_DNS_UPSTREAM is ignored: TUNNEL_MODE=${AER_TUNNEL_MODE} runs no Ziti DNS server"
        fi
    fi
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

    # none passes no tunnel flag, so auto_enroll writes no tunnel binding and
    # leaves isTunnelerEnabled alone (it only sets that on its admin-credential
    # router-creation path, which the AER never uses).
    local tunnel_option=""
    case "${AER_TUNNEL_MODE}" in
        auto) tunnel_option="--autoTunnelListener" ;;
        host) tunnel_option="--tunnelListener host"
              log "TUNNEL_MODE '${TUNNEL_MODE:-}'; using host mode" ;;
        none) log "TUNNEL_MODE 'none'; no tunnel listener" ;;
    esac

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

    # auto_enroll only touches DNS when a tunnel flag is present, but say so
    # explicitly for none.
    if [[ "${AER_TUNNEL_MODE}" == "none" ]]; then
        AER_ENROLL_ARGS+=(--skipDNS)
    fi
}

############### config.yml rendering ###############
# FX_render_config runs on every start (and before every ziti restart) after
# enrollment.  It treats the env as desired state and edits config.yml only
# where the file differs, so re-running it with the same env is a no-op.

# Brings the tunnel binding in line with AER_TUNNEL_MODE.  A binding that
# already has the requested mode is left untouched; a new or replaced binding
# uses the same shape auto_enroll would have written at enrollment.
SUBFX_reconcile_tunnel_binding() {
    local cfg="$1" count cur
    count=$(yq e '[.listeners[] | select(.binding == "tunnel")] | length' "${cfg}")
    cur=$(yq e '[.listeners[] | select(.binding == "tunnel")] | .[0].options.mode // ""' "${cfg}")

    case "${AER_TUNNEL_MODE}" in
        none)
            [[ "${count}" -eq 0 ]] && return 0
            log "TUNNEL_MODE=none — removing tunnel binding (mode '${cur}') from config.yml"
            yq e -i 'del(.listeners[] | select(.binding == "tunnel"))' "${cfg}"
            ok "Tunnel binding removed"
            return 0
            ;;
        host)
            [[ "${count}" -gt 0 && "${cur}" == "host" ]] && return 0
            log "TUNNEL_MODE=host — setting tunnel binding to mode host (was '${cur:-none}')"
            SUBFX_set_tunnel_binding "${cfg}" "${count}" '{"binding": "tunnel", "options": {"mode": "host"}}'
            ;;
        auto)
            [[ "${count}" -gt 0 && "${cur}" == "tproxy" ]] && return 0
            local iface lan_ip
            iface=$(SUBFX_detect_default_iface)
            [[ -n "${iface}" ]] && lan_ip=$(SUBFX_detect_iface_ipv4 "${iface}")
            [[ -n "${iface}" && -n "${lan_ip:-}" ]] \
                || err "TUNNEL_MODE=auto needs a default-route interface with an IPv4 address to build the tproxy binding; none found"
            log "TUNNEL_MODE=auto — setting tunnel binding to mode tproxy on ${iface}/${lan_ip} (was '${cur:-none}')"
            TUN_RESOLVER="udp://${lan_ip}:53" TUN_LANIF="${iface}" SUBFX_set_tunnel_binding "${cfg}" "${count}" \
                '{"binding": "tunnel", "options": {"mode": "tproxy", "resolver": strenv(TUN_RESOLVER), "lanIf": strenv(TUN_LANIF), "dnsSvcIpRange": "100.64.0.0/10"}}'
            ;;
    esac

    ok "Tunnel binding set to ${AER_TUNNEL_MODE}"
    warn "The tunnel mode changed after enrollment.  The edge router must be tunneler-enabled"
    warn "on the controller (NetFoundry console) for ${AER_TUNNEL_MODE} mode to carry traffic."
}

# Replaces the tunnel binding in place ($2 > 0) or appends one.  $3 is a yq
# map literal; yq-built nodes are emitted in block style like the rest of the file.
SUBFX_set_tunnel_binding() {
    local cfg="$1" count="$2" binding="$3"
    if [[ "${count}" -gt 0 ]]; then
        yq e -i "(.listeners[] | select(.binding == \"tunnel\")) = ${binding}" "${cfg}"
    else
        yq e -i ".listeners += [${binding}]" "${cfg}"
    fi
}

# Applies the validated env to config.yml.  Call after enrollment and
# FX_validate_env, with ZITI_VERSION set to the installed binary's version.
FX_render_config() {
    local cfg="${AER_CONFIG_FILE}"
    if [[ ! -f "${cfg}" ]]; then
        warn "config.yml not found at ${cfg}; skipping YAML update"
        return
    fi

    AER_VERSION_KNOWN=false
    SUBFX_parse_version "${ZITI_VERSION:-}" && AER_VERSION_KNOWN=true
    AER_FINAL_UPSTREAMS=()
    AER_UPSTREAM_TRUNCATED=false

    SUBFX_reconcile_tunnel_binding "${cfg}"

    if [[ "${_DNS_ACTIVE}" == "true" ]]; then
        SUBFX_dns_update_config_yaml
    fi

    FX_log_summary
}

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
    local upstreams=("${AER_DNS_UPSTREAMS[@]}")
    if [[ ${#upstreams[@]} -eq 0 ]]; then
        local raw_ip
        raw_ip=$(SUBFX_dns_detect_fallback)
        if SUBFX_is_ipv6 "${raw_ip}"; then
            upstreams=("udp://[${raw_ip}]:53")
        else
            upstreams=("udp://${raw_ip}:53")
        fi
        log "ZITI_DNS_UPSTREAM not set — auto-detected: ${upstreams[0]}"
    fi

    # Version guard: ziti < 2.0.0 rejects anything but a string dnsUpstream
    # (hard config error), so a list is only written when the installed
    # binary is known to be >= 2.0.0.  Otherwise keep the first entry, which
    # is valid on every version.
    if [[ ${#upstreams[@]} -gt 1 ]]; then
        if [[ "${AER_VERSION_KNOWN}" == "true" ]] && SUBFX_version_ge 2 0 0; then
            :
        else
            if [[ "${AER_VERSION_KNOWN}" == "true" ]]; then
                warn "Router ${ZITI_VERSION} accepts a single dnsUpstream; multiple upstreams require ziti >= 2.0.0."
            else
                warn "Router version could not be determined ('${ZITI_VERSION:-}'); writing a single dnsUpstream, which is valid on every version."
            fi
            warn "Using ${upstreams[0]}; dropped: ${upstreams[*]:1}"
            upstreams=("${upstreams[0]}")
            AER_UPSTREAM_TRUNCATED=true
        fi
    fi
    AER_FINAL_UPSTREAMS=("${upstreams[@]}")

    if [[ ${#upstreams[@]} -eq 1 ]]; then
        # Single entry: scalar string, byte-identical to entrypoint v2.0.
        DNS_UPSTREAM="${upstreams[0]}" \
            yq e '(.listeners[] | select(.binding == "tunnel") | .options.dnsUpstream) = env(DNS_UPSTREAM)' \
            -i "${config_file}"
        ok "dnsUpstream set to ${upstreams[0]}"
    else
        DNS_UPSTREAM_LIST="$(IFS=,; echo "${upstreams[*]}")" \
            yq e '(.listeners[] | select(.binding == "tunnel") | .options.dnsUpstream) = (strenv(DNS_UPSTREAM_LIST) | split(","))' \
            -i "${config_file}"
        ok "dnsUpstream set to [${upstreams[*]}]"
    fi
}

# One line with the effective settings, logged after every render.
FX_log_summary() {
    local upstream_desc="n/a (DNS management inactive)"
    if [[ "${_DNS_ACTIVE}" == "true" ]]; then
        upstream_desc="[${AER_FINAL_UPSTREAMS[*]}] truncated=${AER_UPSTREAM_TRUNCATED}"
    fi
    log "Effective settings: tunnel=${AER_TUNNEL_MODE}" \
        "| dnsUpstream=${upstream_desc}" \
        "| routerVersion=${ZITI_VERSION:-unknown}"
}
