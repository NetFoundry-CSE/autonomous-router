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
AER_CERT_DIR="${AER_CERT_DIR:-/etc/netfoundry/certs}"

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

    SUBFX_validate_advertise
    SUBFX_validate_link_listener

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

# Sets AER_EDGE_ADVERTISE_HOST from ADVERTISE_ADDRESS (HOST:PORT).
# IPv6 is rejected: auto_enroll derives the cert SAN with split(":"), which
# cannot handle IPv6 literals.
SUBFX_validate_advertise() {
    AER_EDGE_ADVERTISE_HOST=""
    [[ -n "${ADVERTISE_ADDRESS:-}" ]] || return 0

    local host="" port=""
    if [[ "${ADVERTISE_ADDRESS}" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    fi
    if [[ -z "${host}" ]] || ! SUBFX_is_port "${port}" \
        || ! { SUBFX_is_ipv4 "${host}" || SUBFX_is_dns_name "${host}"; }; then
        err "ADVERTISE_ADDRESS='${ADVERTISE_ADDRESS}' is invalid; expected HOST:PORT with an IPv4 address or DNS name (IPv6 is not supported), e.g. 203.0.113.10:443"
    fi
    AER_EDGE_ADVERTISE_HOST="${host}"
}

# Sets AER_LINK_STATE (true | false | unmanaged) and, when true,
# AER_LINK_BIND, AER_LINK_ADVERTISE_HOST, AER_LINK_ADVERTISE, AER_LINK_OUTQ.
#   ZITI_LINK_LISTENER_ENABLED unset  -> config.yml link listeners left as-is
#   ZITI_LINK_LISTENER_ENABLED=false  -> link listeners removed
#   ZITI_LINK_LISTENER_ENABLED=true   -> exactly one transport link listener
SUBFX_validate_link_listener() {
    local enabled="${ZITI_LINK_LISTENER_ENABLED:-}"
    enabled="${enabled//[[:space:]]/}"
    case "${enabled,,}" in
        "")          AER_LINK_STATE="unmanaged" ;;
        true|yes|1)  AER_LINK_STATE="true" ;;
        false|no|0)  AER_LINK_STATE="false" ;;
        *) err "ZITI_LINK_LISTENER_ENABLED='${ZITI_LINK_LISTENER_ENABLED}' is invalid; allowed values: true, false (or unset to leave config.yml link listeners unchanged)" ;;
    esac

    AER_LINK_ADVERTISE=""
    if [[ "${AER_LINK_STATE}" != "true" ]]; then
        if [[ -n "${ZITI_LINK_ADVERTISE:-}" ]]; then
            warn "ZITI_LINK_ADVERTISE is ignored: set ZITI_LINK_LISTENER_ENABLED=true to configure a link listener"
        fi
        return 0
    fi

    local adv="${ZITI_LINK_ADVERTISE:-}"
    adv="${adv//[[:space:]]/}"
    [[ -n "${adv}" ]] \
        || err "ZITI_LINK_ADVERTISE is required when ZITI_LINK_LISTENER_ENABLED=true; set it to the public IPv4 address or DNS name other routers will dial"
    if [[ "${adv}" == *:* ]]; then
        err "ZITI_LINK_ADVERTISE='${adv}' is invalid; allowed values: an IPv4 address or DNS name (IPv6 and HOST:PORT are not supported; set the port with ZITI_LINK_ADVERTISE_PORT)"
    fi
    SUBFX_is_ipv4 "${adv}" || SUBFX_is_dns_name "${adv}" \
        || err "ZITI_LINK_ADVERTISE='${adv}' is invalid; allowed values: an IPv4 address or DNS name"

    local port="${ZITI_LINK_ADVERTISE_PORT:-443}"
    SUBFX_is_port "${port}" \
        || err "ZITI_LINK_ADVERTISE_PORT='${port}' is invalid; allowed values: 1-65535 (default 443)"

    local bind="${ZITI_LINK_BIND:-tls:0.0.0.0:443}" bind_port=""
    [[ "${bind}" =~ ^tls:[^[:space:]]+:([0-9]+)$ ]] && bind_port="${BASH_REMATCH[1]}"
    SUBFX_is_port "${bind_port}" \
        || err "ZITI_LINK_BIND='${bind}' is invalid; expected tls:ADDRESS:PORT (default tls:0.0.0.0:443)"

    local outq="${ZITI_LINK_OUTQUEUESIZE:-16}"
    [[ "${outq}" =~ ^[0-9]+$ ]] && (( 10#${outq} > 0 )) \
        || err "ZITI_LINK_OUTQUEUESIZE='${outq}' is invalid; expected a positive integer (default 16)"

    AER_LINK_BIND="${bind}"
    AER_LINK_ADVERTISE_HOST="${adv}"
    AER_LINK_ADVERTISE="tls:${adv}:${port}"
    AER_LINK_OUTQ="$((10#${outq}))"
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

    # Explicit --linkListeners wins over auto_enroll's own defaults and puts
    # the advertise host into the cert SANs.  --assumePublic is not used.
    if [[ "${AER_LINK_STATE}" == "true" ]]; then
        AER_ENROLL_ARGS+=(--linkListeners transport "${AER_LINK_BIND}" "${AER_LINK_ADVERTISE}" "${AER_LINK_OUTQ}")
    fi

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

############### Certificate SAN checks ###############
# Listeners present server_cert.pem, whose SANs were fixed at enrollment.  An
# advertised address the cert does not cover breaks TLS verification for
# whoever dials it, and only re-enrollment can add a SAN.

# Returns 0 if host $1 is covered by the router cert SANs, 1 if not, and 2 if
# that cannot be checked (no cert yet, or openssl unavailable).  Sets
# AER_CERT_PATH and AER_CERT_SANS for messages.
SUBFX_cert_has_san() {
    local host="${1,,}" f san sans
    AER_CERT_PATH=""
    AER_CERT_SANS=""
    for f in server_cert.pem cert.pem client.cert; do
        if [[ -s "${AER_CERT_DIR}/${f}" ]]; then
            AER_CERT_PATH="${AER_CERT_DIR}/${f}"
            break
        fi
    done
    [[ -n "${AER_CERT_PATH}" ]] || return 2
    command -v openssl >/dev/null 2>&1 || return 2

    sans=$(openssl x509 -in "${AER_CERT_PATH}" -noout -ext subjectAltName 2>/dev/null \
        | sed -n '2,$p' | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/^IP Address:/IP:/' \
        | grep -E '^(DNS|IP):' || true)
    AER_CERT_SANS=$(echo "${sans}" | tr '\n' ' ')
    AER_CERT_SANS="${AER_CERT_SANS% }"

    while read -r san; do
        case "${san}" in
            IP:*)
                [[ "${san#IP:}" == "${host}" ]] && return 0 ;;
            DNS:*)
                san="${san#DNS:}"
                san="${san,,}"
                [[ "${san}" == "${host}" ]] && return 0
                # Single-label wildcard: *.corp.example matches er1.corp.example.
                if [[ "${san}" == \*.* ]] && ! SUBFX_is_ipv4 "${host}" \
                    && [[ "${host}" == *.* && "${host#*.}" == "${san#\*.}" ]]; then
                    return 0
                fi ;;
        esac
    done <<< "${sans}"
    return 1
}

# Checks that $2 (the host behind env var $1) is in the cert SANs.
# $3=change: config.yml is about to be changed to use it, so a missing SAN is
# fatal.  $3=keep: config.yml already uses it, so only warn.
SUBFX_require_san() {
    local var="$1" host="$2" intent="$3" rc=0
    SUBFX_cert_has_san "${host}" || rc=$?
    case "${rc}" in
        0) return 0 ;;
        2) warn "Cannot verify ${var} host '${host}' against the router certificate (${AER_CERT_PATH:-no cert found}); continuing" ;;
        *)
            if [[ "${intent}" == "change" ]]; then
                err "${var}: '${host}' is not in the router certificate SANs (${AER_CERT_PATH}: ${AER_CERT_SANS})." \
                    "Advertising an address the certificate does not cover requires re-enrollment:" \
                    "stop the container, move ./ziti_router aside, and start again with a new REG_KEY" \
                    "from the NetFoundry console (or revert ${var})."
            fi
            warn "!!! ${var}: '${host}' is in config.yml but NOT in the router certificate SANs"
            warn "!!! (${AER_CERT_PATH}: ${AER_CERT_SANS}).  Clients dialing it will fail TLS"
            warn "!!! verification.  Re-enroll the router to add it to the certificate." ;;
    esac
}

############### Listener reconciliation ###############

# Applies ADVERTISE_ADDRESS to the edge listener.  Unset leaves it alone:
# auto_enroll's defaults depend on the LAN IP at enrollment time, and
# re-detecting them would break the router whenever DHCP moves it.
SUBFX_reconcile_edge_advertise() {
    local cfg="$1" count cur
    [[ -n "${ADVERTISE_ADDRESS:-}" ]] || return 0

    count=$(yq e '[.listeners[] | select(.binding == "edge")] | length' "${cfg}")
    if [[ "${count}" -eq 0 ]]; then
        warn "ADVERTISE_ADDRESS is set but config.yml has no edge listener; not applied"
        return 0
    fi
    cur=$(yq e '[.listeners[] | select(.binding == "edge")] | .[0].options.advertise // ""' "${cfg}")

    if [[ "${cur}" == "${ADVERTISE_ADDRESS}" ]]; then
        SUBFX_require_san ADVERTISE_ADDRESS "${AER_EDGE_ADVERTISE_HOST}" keep
        return 0
    fi

    SUBFX_require_san ADVERTISE_ADDRESS "${AER_EDGE_ADVERTISE_HOST}" change
    log "Changing edge listener advertise from '${cur}' to '${ADVERTISE_ADDRESS}'"
    EDGE_ADVERTISE="${ADVERTISE_ADDRESS}" \
        yq e -i '(.listeners[] | select(.binding == "edge") | .options.advertise) = strenv(EDGE_ADVERTISE)' "${cfg}"
    ok "Edge listener advertise set to ${ADVERTISE_ADDRESS}"
}

# Applies AER_LINK_STATE to link.listeners (see SUBFX_validate_link_listener).
# The listener shape matches auto_enroll's template, so a router enrolled
# with the same settings is not rewritten.
SUBFX_reconcile_link_listener() {
    local cfg="$1" cur want
    local expr='[{"binding": "transport", "bind": strenv(LINK_BIND), "advertise": strenv(LINK_ADVERTISE), "options": {"outQueueSize": env(LINK_OUTQ)}}]'

    case "${AER_LINK_STATE}" in
        unmanaged)
            return 0 ;;
        false)
            [[ "$(yq e '.link.listeners | length' "${cfg}")" -gt 0 ]] || return 0
            log "ZITI_LINK_LISTENER_ENABLED=false — removing link listeners from config.yml"
            yq e -i 'del(.link.listeners)' "${cfg}"
            ok "Link listeners removed"
            return 0 ;;
    esac

    export LINK_BIND="${AER_LINK_BIND}" LINK_ADVERTISE="${AER_LINK_ADVERTISE}" LINK_OUTQ="${AER_LINK_OUTQ}"
    cur=$(yq e -o=json -I=0 '.link.listeners // []' "${cfg}")
    want=$(yq -n -o=json -I=0 "${expr}")

    if [[ "${cur}" == "${want}" ]]; then
        SUBFX_require_san ZITI_LINK_ADVERTISE "${AER_LINK_ADVERTISE_HOST}" keep
    else
        SUBFX_require_san ZITI_LINK_ADVERTISE "${AER_LINK_ADVERTISE_HOST}" change
        log "Setting link listener: bind ${AER_LINK_BIND}, advertise ${AER_LINK_ADVERTISE}, outQueueSize ${AER_LINK_OUTQ}"
        yq e -i ".link.listeners = ${expr}" "${cfg}"
        ok "Link listener set to ${AER_LINK_ADVERTISE}"
    fi
    unset LINK_BIND LINK_ADVERTISE LINK_OUTQ

    if [[ "$(yq e '[.link.dialers[] | select(.binding == "transport")] | length' "${cfg}")" -eq 0 ]]; then
        warn "config.yml has no link dialer with binding 'transport'; this router will accept links but not dial them"
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
    SUBFX_reconcile_edge_advertise "${cfg}"
    SUBFX_reconcile_link_listener "${cfg}"

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
    local link_desc="${AER_LINK_ADVERTISE}"
    case "${AER_LINK_STATE}" in
        unmanaged) link_desc="unmanaged (config.yml left as-is)" ;;
        false)     link_desc="disabled" ;;
    esac
    if [[ "${_DNS_ACTIVE}" == "true" ]]; then
        upstream_desc="[${AER_FINAL_UPSTREAMS[*]}] truncated=${AER_UPSTREAM_TRUNCATED}"
    fi
    log "Effective settings: tunnel=${AER_TUNNEL_MODE}" \
        "| dnsUpstream=${upstream_desc}" \
        "| linkAdvertise=${link_desc}" \
        "| routerVersion=${ZITI_VERSION:-unknown}"
}
