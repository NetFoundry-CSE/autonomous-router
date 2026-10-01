#!/usr/bin/env bash
# docker-entrypoint.sh — NetFoundry Autonomous Edge Router
#
# Copyright 2026 NetFoundry Inc.
# Licensed under the Apache License, Version 2.0
# https://www.apache.org/licenses/LICENSE-2.0
#
# NFRAGALE - Made by a human at NetFoundry.
#
# Version history:
#   1.0  09/17/2024  V8 network support; ziti_auto_enroll binary download
#   1.1  09/18/2024  Use client endpoint for controller version query
#   1.2  05/20/2025  ADVERTISE_ADDRESS support
#   1.3  05/30/2025  TUNNEL_MODE support; sandbox v8 registration fix
#   1.4  06/04/2025  ADVERTISE_ADDRESS changed to IP:PORT format
#   1.5  06/11/2025  Rebuild
#   2.0  04/02/2026  DISABLE_AUTO_UPDATE, ZITI_DNS_*, HOSTS_ENTRIES; code cleanup
#                     Remove HOSTS_ENTRIES block from /etc/hosts on container shutdown
#                     Fix DNS: add ~. routing domain; clear per-link DNS domains in all-mode
#                     Move DNS config to post-launch; wait for Ziti DNS ready in all-mode
#                     Remove resolved drop-in and restart systemd-resolved on shutdown
#                     ZITI_VERSION_OVERRIDE — pin the router binary to a specific version
#   2.1  10/01/2026  TUNNEL_MODE=none; TUNNEL_MODE validated and applied on every start
#                     Multiple ZITI_DNS_UPSTREAM values (version-guarded), ZITI_DNS_UPSTREAM_MODE
#                     ZITI_LINK_* fabric link listener; ADVERTISE_ADDRESS applied post-enrollment
#                     with a cert SAN check; rendering moved to aer-lib.sh
#
# Environment variables:
#   REG_KEY                Registration key for initial router enrollment
#   HTTPS_PROXY            Proxy URL (e.g. http://proxy.corp:3128)
#   ADVERTISE_ADDRESS      Advertised HOST:PORT for edge TLS listener (IPv4 or
#                          DNS name).  Applied on every start; after enrollment
#                          HOST must already be in the router cert SANs.
#   TUNNEL_MODE            auto | host | none (case-insensitive, unset = host).
#                          auto: tproxy tunnel listener + Ziti DNS server.
#                          host: tunnel listener in host mode, no DNS.
#                          none: no tunnel listener.  ALL Ziti DNS features
#                          require TUNNEL_MODE=auto.  Validated and applied to
#                          config.yml on every start.
#   ZITI_LINK_LISTENER_ENABLED  true: one "transport" link listener; false:
#                          remove link listeners; unset: leave config.yml as-is.
#   ZITI_LINK_ADVERTISE    Public IPv4/DNS name other routers dial (required
#                          when enabled; must be in the cert SANs after enrollment)
#   ZITI_LINK_ADVERTISE_PORT  Default 443
#   ZITI_LINK_BIND         Default tls:0.0.0.0:443
#   ZITI_LINK_OUTQUEUESIZE Default 16
#   VERBOSE                Any non-empty value enables verbose ziti logging (-v)
#
#   DISABLE_AUTO_UPDATE    Set to "true" to skip controller-version checks.
#                          The supervisor loop still runs: Ziti is restarted on
#                          crash and DNS health is monitored.  Default: version
#                          checks run every 60 s.
#
#   ZITI_DNS_CONFIGURE     Only evaluated when TUNNEL_MODE=auto.  Set to "false"
#                          to suppress all DNS configuration even in auto mode.
#                          Defaults to "true" when TUNNEL_MODE=auto.
#   ZITI_DNS_MODE          "all"  — route every DNS query through Ziti DNS
#                          "domains" — route only ZITI_DNS_DOMAINS
#   ZITI_DNS_IP            Ziti DNS server IP (auto-detected from LAN if unset)
#   ZITI_DNS_DOMAINS       Space-separated domain list (required for MODE=domains)
#                          e.g. "lan ziti corp internal"
#   ZITI_DNS_FALLBACK      Fallback DNS IP (auto-detected from host if unset)
#   ZITI_DNS_RANGE         CIDR to write into config.yml dnsSvcIpRange
#                          e.g. "100.65.0.0/24"
#   ZITI_DNS_UPSTREAM      Upstream DNS written into config.yml dnsUpstream.
#                          Auto-detected from the host's current resolver when
#                          unset (same source as ZITI_DNS_FALLBACK, formatted
#                          as udp://IP:53).  Comma/space separated list; bare
#                          hosts become udp://HOST:53.  More than one entry is
#                          written as a list only for ziti >= 2.0.0.
#   ZITI_DNS_UPSTREAM_MODE parallel | serial | failover | random (ziti >= 2.1.0).
#                          Written only with 2+ upstreams.
#   ZITI_DNS_DISABLE_MDNS  Set to "true" to write MulticastDNS=no into the
#                          resolved drop-in.  Required when your DNS server
#                          serves .local records — without this, systemd-resolved
#                          intercepts .local on the mDNS stack (RFC 6762) before
#                          the query ever reaches DNS, returning SERVFAIL.
#   ZITI_DNS_HEALTH_THRSH  Consecutive failed DNS probes before the resolver
#                          is reverted to host DNS and Ziti is restarted.
#                          Default: 3.  Each probe runs once per supervisor loop
#                          iteration (~60 s), so the default triggers after ~3 min
#                          of unresponsive Ziti DNS.
#
#   ZITI_VERSION_OVERRIDE  Pin the router binary to a specific version instead of
#                          following the controller.  Bypasses all version checks
#                          and the auto-update loop.  Format: vMAJOR.MINOR.PATCH
#                          e.g. "v1.6.0"
#
#   HOSTS_ENTRIES          Newline or semicolon-separated "ip host [alias ...]"
#                          records injected into /etc/hosts inside a managed
#                          block so Ziti never intercepts them.
#                          e.g. "192.168.1.10 db.internal db;10.0.0.5 ldap.corp"
#                          The block is automatically removed when the container
#                          shuts down (SIGTERM/SIGINT or natural exit).
#                          NOTE: In Docker host-network mode the container has
#                          its own /etc/hosts.  To modify the HOST's file, add
#                          to your compose volumes:
#                            - /etc/hosts:/etc/hosts

set -eo pipefail

VERSION="2.1"
SystemLogo='
    _   __     __  ______                      __
   / | / /__  / /_/ ____/___  __  ______  ____/ /______  __
  /  |/ / _ \/ __/ /_  / __ \/ / / / __ \/ __  / ___/ / / /
 / /|  /  __/ /_/ __/ / /_/ / /_/ / / / / /_/ / /  / /_/ /
/_/ |_/\___/\__/_/    \____/\__,_/_/ /_/\__,_/_/   \__, /
                                                  /____/
                    __________ ____
                   /     ____// __ \
                  / /|  __/  / /_/ /
                 / __  /___ / _, _/
                /_/ /_____//_/ |_|

' # Logo.

############### Logging ###############

# log/ok/warn/err, address detection, auto_enroll argv and config.yml
# rendering live in aer-lib.sh so they can be tested without enrolling.
# shellcheck source=aer-lib.sh
source "${AER_LIB:-/aer-lib.sh}"

logo() {
    # Ensure the logo lines are congruent, then print.
    while IFS=$'\n' read -r EachLine; do
        [[ ${#EachLine} -gt ${MaxLogoLine} ]] \
            && MaxLogoLine="${#EachLine}"
        [[ ${#EachLine} -ne 0 ]] && [[ ${#EachLine} -lt ${MinLogoLine} ]] \
            && MinLogoLine="${#EachLine}"
    done < <(printf '%s\n' "${SystemLogo}")

    while IFS=$'\n' read -r EachLine; do
	printf "%-${MaxLogoLine}s\n" "${EachLine}"
    done < <(printf "%s\n" "${SystemLogo}")
}

############### Registration ###############

FX_register_router() {
    mkdir -p /etc/netfoundry/certs

    FX_build_enroll_args

    # IMPORTANT: We skipSystemd in the auto_enroll because we must apply/deapply rules
    #  during each startup, not only at enrollment. Failing to do this will cause the host
    #  to become unable to query DNS outside of a running Ziti instance.
    /ziti_router_auto_enroll "${AER_ENROLL_ARGS[@]}"
}

############### Version management ###############

FX_get_controller_version() {
    log "Checking controller version..."
    CONTROLLER_VERSION=""

    local addr
    addr=$(awk -F ':' '/endpoint/ {print $3; exit}' config.yml 2>/dev/null || true)

    if [[ -z "${addr}" ]]; then
        warn "No controller address found in config.yml; skipping upgrade check"
        return
    fi

    log "Controller address: ${addr}"

    local rep
    rep=$(curl -sf -k "https://${addr}:443/edge/client/v1/version" 2>/dev/null || true)

    if jq -e . >/dev/null 2>&1 <<< "${rep}"; then
        CONTROLLER_VERSION=$(jq -r .data.version <<< "${rep}")
    else
        warn "Failed to retrieve controller version"
    fi

    log "Controller version: ${CONTROLLER_VERSION:-unknown}"
}

SUBFX_download_ziti_binary() {
    log "Downloading ziti binary: ${upgradelink}"
    curl -fL -o ziti-linux.tar.gz "${upgradelink}"

    local main_ver dot_ver
    main_ver=$(awk -F '.' '{print $1}' <<< "${CONTROLLER_VERSION}" | tr -d 'v')
    dot_ver=$(awk  -F '.' '{print $2}' <<< "${CONTROLLER_VERSION}")

    if [[ "${main_ver}" -lt 1 && "${dot_ver}" -lt 27 ]]; then
        err "Ziti version ${CONTROLLER_VERSION} is not supported (minimum 0.27)"
    fi

    rm -f ziti
    if [[ "${main_ver}" -lt 1 && "${dot_ver}" -lt 29 ]]; then
        tar xf ziti-linux.tar.gz ziti/ziti --strip-components 1
    else
        tar xf ziti-linux.tar.gz ziti
    fi
    chmod +x ziti
    rm -f ziti-linux.tar.gz

    mkdir -p /opt/openziti/bin
    cp ziti /opt/openziti/bin/
    log "Installed: /opt/openziti/bin/ziti"
}

FX_upgrade_ziti() {
    local release="${CONTROLLER_VERSION#v}"
    log "Upgrading ziti to ${release}..."

    local response
    response=$(curl -sfk \
        "https://gateway.production.netfoundry.io/core/v2/network-versions?zitiVersion=${release}")

    if ! jq -e . >/dev/null 2>&1 <<< "${response}"; then
        warn "Failed to retrieve upgrade metadata from NetFoundry console"
        return
    fi

    case "$(uname -m)" in
        aarch64) upgradelink=$(jq -r '._embedded["network-versions"][0].jsonNode.zitiBinaryBundleLinuxARM64' <<< "${response}") ;;
        armv7l)  upgradelink=$(jq -r '._embedded["network-versions"][0].jsonNode.zitiBinaryBundleLinuxARM'   <<< "${response}") ;;
        *)       upgradelink=$(jq -r '._embedded["network-versions"][0].jsonNode.zitiBinaryBundleLinuxAMD64'  <<< "${response}") ;;
    esac

    SUBFX_download_ziti_binary
}

############### DNS configuration (ZITI_DNS_* env vars) ###############
# Requires the compose file to provide:
#   cap_add: [NET_ADMIN]
#   pid: host
#   volumes:
#     - /etc/systemd:/etc/systemd                              # write resolved drop-in conf
#     - /run/systemd:/run/systemd                              # systemctl varlink socket



SUBFX_dns_write_resolved_conf() {
    local dns_ip="$1" mode="$2" fallback="$3"
    shift 3
    local domains=("$@")
    local conf_file="/etc/systemd/resolved.conf.d/ziti.conf"

    # Optional: disable mDNS interception so .local queries reach DNS.
    # systemd-resolved intercepts .local on the mDNS stack (RFC 6762) before
    # DNS routing applies, even with "Domains=~.", returning SERVFAIL if your
    # DNS server serves .local records.  Set ZITI_DNS_DISABLE_MDNS=true to
    # add MulticastDNS=no to the drop-in, which prevents that interception.
    local mdns_line=""
    if [[ "${ZITI_DNS_DISABLE_MDNS:-}" == "true" ]]; then
        mdns_line=$'\nMulticastDNS=no'
        log "ZITI_DNS_DISABLE_MDNS=true — mDNS interception disabled"
    fi

    mkdir -p "$(dirname "${conf_file}")"

    if [[ "${mode}" == "all" ]]; then
        log "Routing ALL DNS queries through Ziti DNS at ${dns_ip}"
        # Domains=~. makes this the default-route DNS server, ensuring it wins
        # over any per-link DNS servers that systemd-resolved would otherwise
        # prefer for domains they advertise (e.g. DHCP-pushed search domains).
        cat > "${conf_file}" <<EOF
[Resolve]
DNS=${dns_ip}
Domains=~.
FallbackDNS=${fallback}${mdns_line}
EOF
    else
        local domain_str=""
        for d in "${domains[@]}"; do
            domain_str+="~${d#\~} "
        done
        domain_str="${domain_str% }"
        log "Routing domains [${domain_str}] through Ziti DNS at ${dns_ip}"
        cat > "${conf_file}" <<EOF
[Resolve]
DNS=${dns_ip}
Domains=${domain_str}
FallbackDNS=${fallback}${mdns_line}
EOF
    fi

    ok "Written ${conf_file}"
    # Write a sentinel file so the parent shell can detect this across the
    # subshell boundary (FX_configure_ziti_dns runs backgrounded with &).
    touch "${_DNS_CONF_SENTINEL}"

    if systemctl restart systemd-resolved 2>/dev/null; then
        ok "systemd-resolved restarted"
    else
        warn "Could not restart systemd-resolved — mount /run/systemd:/run/systemd and ensure pid: host"
    fi
}


# Wait until Ziti's DNS port (UDP 53) is actually accepting queries before
# we switch systemd-resolved over to it.  Only needed in "all" mode — if we
# flip the global DNS to Ziti before its listener is ready, every DNS query
# gets ECONNREFUSED and systemd-resolved does NOT fall back to FallbackDNS on
# connection-refused (only on timeout), leaving the host with no DNS at all.
#
# Polls every 2 s up to ZITI_DNS_WAIT_TIMEOUT seconds (default 60).
SUBFX_wait_for_ziti_dns() {

    local dns_ip="$1"
    local timeout="${ZITI_DNS_WAIT_TIMEOUT:-60}"
    local elapsed=0

    log "Waiting for Ziti DNS to be ready at ${dns_ip}:53 (timeout ${timeout}s)..."
    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        # Send a minimal DNS query; success means Ziti is listening
        if dig +time=1 +tries=1 +short "@${dns_ip}" . NS >/dev/null 2>&1; then
            ok "Ziti DNS is ready at ${dns_ip}:53 (${elapsed}s)"
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    warn "Ziti DNS not ready after ${timeout}s — skipping systemd-resolved reconfiguration."
    warn "DNS will remain on current resolver. Set ZITI_DNS_WAIT_TIMEOUT to increase the wait."
    return 1
}

# Single-shot DNS health probe used by the runtime supervisor loop.
# Returns 0 if Ziti DNS is responding, 1 if not.
SUBFX_check_ziti_dns() {
    local dns_ip="$1"
    dig +time=1 +tries=1 +short "@${dns_ip}" . NS >/dev/null 2>&1
}

_RESOLVED_CONF="/etc/systemd/resolved.conf.d/ziti.conf"
# Sentinel lives in the container's /run/ (not the host volume) so it is
# fresh on every container start.  It crosses the subshell boundary:
# FX_configure_ziti_dns runs backgrounded with &, so variables it sets are
# invisible to the parent shell — the sentinel on disk is used instead.
_DNS_CONF_SENTINEL="/run/ziti-dns-conf-written"

FX_remove_dns_conf() {
    [[ -f "${_DNS_CONF_SENTINEL}" ]] || return 0

    log "Removing ${_RESOLVED_CONF} and restarting systemd-resolved..."
    rm -f "${_RESOLVED_CONF}" "${_DNS_CONF_SENTINEL}"

    if systemctl restart systemd-resolved 2>/dev/null; then
        ok "systemd-resolved restarted — host DNS restored"
    else
        warn "Could not restart systemd-resolved; host DNS config may still reference Ziti."
        warn "Run: sudo systemctl restart systemd-resolved"
    fi
}

FX_configure_ziti_dns() {
    # Only called when _DNS_ACTIVE=true (TUNNEL_MODE=auto + ZITI_DNS_CONFIGURE not false).
    # config.yml patches (dnsUpstream, dnsSvcIpRange) were applied pre-launch.
    # This function handles only the systemd-resolved configuration.
    log "Configuring systemd-resolved for Ziti DNS..."

    local mode="${ZITI_DNS_MODE:-}"

    if [[ -z "${mode}" ]]; then
        log "ZITI_DNS_MODE not set; skipping systemd-resolved configuration"
        return
    fi

    if [[ "${mode}" != "all" && "${mode}" != "domains" ]]; then
        warn "Unknown ZITI_DNS_MODE '${mode}' (expected 'all' or 'domains'); skipping"
        return
    fi

    local dns_ip="${ZITI_DNS_IP:-}"
    local fallback="${ZITI_DNS_FALLBACK:-}"
    read -r -a domains <<< "${ZITI_DNS_DOMAINS:-}"

    if [[ "${mode}" == "domains" && ${#domains[@]} -eq 0 ]]; then
        warn "ZITI_DNS_MODE=domains but ZITI_DNS_DOMAINS is empty; skipping"
        return
    fi

    if [[ -z "${dns_ip}" ]]; then
        dns_ip=$(SUBFX_dns_detect_lan_ip)
        [[ -n "${dns_ip}" ]] || err "Cannot auto-detect LAN IP; set ZITI_DNS_IP"
        log "Auto-detected Ziti DNS IP: ${dns_ip}"
    fi

    if [[ -z "${fallback}" ]]; then
        fallback=$(SUBFX_dns_detect_fallback)
        log "Auto-detected fallback DNS: ${fallback}"
    fi

    # In all-mode: wait for Ziti DNS to be ready before reconfiguring resolved.
    # This prevents the window where DNS=Ziti but Ziti isn't listening yet —
    # systemd-resolved does NOT fall back on ECONNREFUSED, only on timeout.
    if [[ "${mode}" == "all" ]]; then
        SUBFX_wait_for_ziti_dns "${dns_ip}" || return 0
    fi

    SUBFX_dns_write_resolved_conf "${dns_ip}" "${mode}" "${fallback}" "${domains[@]:-}"
    # Note: in all-mode the Domains=~. catch-all routing domain already ensures
    # Ziti wins all non-specific queries.  Per-link +DefaultRoute flags (e.g.
    # Net30 pushed by DHCP) are lower priority than ~. and need no intervention.
}

############### /etc/hosts injection + cleanup (HOSTS_ENTRIES env var) ###############
# Safely injects static host records into /etc/hosts inside a clearly marked
# managed block.  The block is removed automatically on container shutdown.
#
# Format for HOSTS_ENTRIES (newlines OR semicolons as separators):
#
#   IP + hostname(s)  — written exactly as-is:
#     "192.168.1.10 db.internal db"
#
#   Hostname only — forward DNS lookup before Ziti starts; written as
#   "RESOLVED_IP hostname".  Skipped with a warning if unresolvable:
#     "controller.netfoundry.io"
#
#   IP only — reverse DNS lookup; all returned PTR records become aliases:
#     "10.20.30.84"  →  "10.20.30.84 fragale.lan test.fragale.lan"
#
#   INTERFACE_ASSIGNED — detects the host's primary LAN IP at runtime, then
#   performs a reverse DNS lookup on it.  Useful when the host IP is dynamic:
#     "INTERFACE_ASSIGNED"  →  "10.20.30.5 myhost.lan"
#
# Mixed example:
#   HOSTS_ENTRIES="192.168.1.10 db.internal;10.20.30.84;INTERFACE_ASSIGNED"

_HOSTS_FILE="/etc/hosts"
_HOSTS_BEGIN="# BEGIN ZITI-SAFE-HOSTS"
_HOSTS_END="# END ZITI-SAFE-HOSTS"
_HOSTS_INJECTED=false   # set to true after a successful FX_inject_hosts call

# Returns 0 and prints the IP if $1 looks like an IPv4/IPv6 address.
SUBFX_is_ip() {
    local token="$1"
    # IPv4
    [[ "${token}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "${token}"; return 0; }
    # IPv6 (simple: contains at least one colon)
    [[ "${token}" =~ ^[0-9a-fA-F:]+$ && "${token}" == *:* ]] && { echo "${token}"; return 0; }
    return 1
}

# Reverse-DNS lookup for a single IP.  Returns space-separated hostnames with
# trailing dots stripped, or empty string if none found.
# $1 = IP address   $2 = optional "@resolver" for mDNS/stub bypass
SUBFX_resolve_reverse() {
    local ip="$1" resolver="${2:-}"
    dig +short +time=3 +tries=2 ${resolver} -x "${ip}" 2>/dev/null \
        | sed 's/\.$//' \
        | tr '\n' ' ' \
        | sed 's/[[:space:]]*$//'
}

FX_inject_hosts() {
    log "Injecting HOSTS_ENTRIES into ${_HOSTS_FILE}..."

    # Normalise: semicolons → newlines, trim blanks
    local raw_entries
    raw_entries=$(printf '%s' "${HOSTS_ENTRIES}" \
        | tr ';' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' || true)

    if [[ -z "${raw_entries}" ]]; then
        warn "HOSTS_ENTRIES contains no valid records; nothing injected"
        return
    fi

    # When ZITI_DNS_DISABLE_MDNS=true the system stub resolver (127.0.0.53)
    # intercepts .local queries for mDNS (RFC 6762) and returns SERVFAIL before
    # forwarding to DNS — even before Ziti is involved.  Bypass it by querying
    # the current primary resolver directly for pre-launch hostname resolution.
    local dig_resolver=""
    if [[ "${ZITI_DNS_DISABLE_MDNS:-}" == "true" ]]; then
        local pre_resolver
        pre_resolver=$(SUBFX_dns_detect_fallback)
        dig_resolver="@${pre_resolver}"
        log "ZITI_DNS_DISABLE_MDNS=true — resolving hostnames via ${pre_resolver} (bypassing mDNS stub)"
    fi

    local resolved_entries=""
    local count_ok=0
    local count_skip=0

    while IFS= read -r line; do
        # Split into tokens
        read -r -a tokens <<< "${line}"
        local first="${tokens[0]}"

        if [[ "${first}" == "INTERFACE_ASSIGNED" ]]; then
            # Detect the host's primary LAN IP at runtime, then reverse-lookup
            local iface_ip
            iface_ip=$(SUBFX_dns_detect_lan_ip)
            if [[ -z "${iface_ip}" ]]; then
                warn "INTERFACE_ASSIGNED: could not detect LAN IP — skipping"
                count_skip=$(( count_skip + 1 ))
            else
                log "INTERFACE_ASSIGNED: detected LAN IP ${iface_ip}, performing reverse lookup..."
                local iface_hostnames
                iface_hostnames=$(SUBFX_resolve_reverse "${iface_ip}" "${dig_resolver}")
                if [[ -n "${iface_hostnames}" ]]; then
                    ok "Added Interface Entry:    ${iface_ip} ${iface_hostnames}"
                    resolved_entries+="${iface_ip} ${iface_hostnames}"$'\n'
                    count_ok=$(( count_ok + 1 ))
                else
                    warn "INTERFACE_ASSIGNED: no reverse DNS for ${iface_ip} — skipping"
                    count_skip=$(( count_skip + 1 ))
                fi
            fi

        elif SUBFX_is_ip "${first}" >/dev/null; then
            if [[ ${#tokens[@]} -eq 1 ]]; then
                # IP alone — reverse DNS lookup to get hostname(s)
                log "Reverse-resolving ${first}..."
                local rev_hostnames
                rev_hostnames=$(SUBFX_resolve_reverse "${first}" "${dig_resolver}")
                if [[ -n "${rev_hostnames}" ]]; then
                    ok "Added Reverse Entry:      ${first} ${rev_hostnames}"
                    resolved_entries+="${first} ${rev_hostnames}"$'\n'
                    count_ok=$(( count_ok + 1 ))
                else
                    warn "No reverse DNS for '${first}' — skipping"
                    count_skip=$(( count_skip + 1 ))
                fi
            else
                # IP + explicit hostname(s) — use as-is
                resolved_entries+="${line}"$'\n'
                ok "Added Pre-Resolved Entry: ${tokens[*]}"
                count_ok=$(( count_ok + 1 ))
            fi

        else
            # Hostname-only — forward DNS lookup before Ziti starts
            local hostname="${first}"
            local rest=("${tokens[@]:1}")
            log "Resolving ${hostname} before Ziti starts..."
            local ip
            ip=$(dig +short +time=3 +tries=2 ${dig_resolver} "${hostname}" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
            if [[ -n "${ip}" ]]; then
                local new_line="${ip} ${hostname}"
                [[ ${#rest[@]} -gt 0 ]] && new_line+=" ${rest[*]}"
                ok "Added Resolved Entry:     ${ip} ${hostname}"
                resolved_entries+="${new_line}"$'\n'
                count_ok=$(( count_ok + 1 ))
            else
                warn "Could not resolve '${hostname}' — skipping (DNS not yet available, or name does not exist)"
                count_skip=$(( count_skip + 1 ))
            fi
        fi
    done <<< "${raw_entries}"

    if [[ -z "${resolved_entries}" ]]; then
        warn "No HOSTS_ENTRIES could be resolved; nothing injected"
        return
    fi

    # Remove any previously managed block (idempotent)
    local tmp
    tmp=$(mktemp)
    sed "/^${_HOSTS_BEGIN}/,/^${_HOSTS_END}/d" "${_HOSTS_FILE}" > "${tmp}"

    # Append new managed block
    {
        cat "${tmp}"
        echo "${_HOSTS_BEGIN}"
        printf '%s' "${resolved_entries}"
        echo "${_HOSTS_END}"
    } > "${_HOSTS_FILE}"

    rm -f "${tmp}"

    ok "Injected ${count_ok} entries into ${_HOSTS_FILE}${count_skip:+ (${count_skip} skipped — unresolvable)}"
    _HOSTS_INJECTED=true
}

FX_remove_hosts() {
    [[ "${_HOSTS_INJECTED}" == "true" ]] || return 0

    log "Removing ZITI-SAFE-HOSTS block from ${_HOSTS_FILE}..."

    local tmp
    tmp=$(mktemp)
    sed "/^${_HOSTS_BEGIN}/,/^${_HOSTS_END}/d" "${_HOSTS_FILE}" > "${tmp}"
    cat "${tmp}" > "${_HOSTS_FILE}"
    rm -f "${tmp}"

    ok "ZITI-SAFE-HOSTS block removed from ${_HOSTS_FILE}"
    _HOSTS_INJECTED=false
}

############### Shutdown handler ###############

FX_shutdown() {
    log "Shutting down..."
    kill "${ZITI_PID}" 2>/dev/null || true
    wait "${ZITI_PID}" 2>/dev/null || true
    FX_remove_hosts
    FX_remove_dns_conf
    exit 0
}

############### Main ###############

logo
echo "NetFoundry Autonomous Edge Router — entrypoint v${VERSION}"

cd /etc/netfoundry/

ARCH=$(uname -m)
log "Architecture: ${ARCH}"

############### Environment validation ###############
# Runs on every start, before registration: invalid values stop the container
# here instead of producing a half-enrolled router or a broken config.yml.
FX_validate_env
log "Tunnel mode: ${AER_TUNNEL_MODE}"

CERT_FILE="certs/cert.pem"
CERT_FILE_OLD="certs/client.cert"

# Global version state
CONTROLLER_VERSION=""
ZITI_VERSION=""
upgradelink=""
zitiVersion=""

############### Registration ###############

if [[ -n "${REG_KEY:-}" ]]; then
    if [[ -s "${CERT_FILE}" ]]; then
        log "Cert file found (${CERT_FILE}); REG_KEY ignored"
    elif [[ -s "${CERT_FILE_OLD}" ]]; then
        log "Cert file found (${CERT_FILE_OLD}); REG_KEY ignored"
    else
        log "Registering router with key: ${REG_KEY}"

        reg_firsttwo="${REG_KEY:0:2}"
        reg_length="${#REG_KEY}"
        reg_url=""

        if [[ "${reg_length}" == "11" ]]; then
            reg_url="https://gateway.production.netfoundry.io/core/v3/edge-router-registrations/${REG_KEY}"
        elif [[ "${reg_length}" == "10" ]]; then
            reg_url="https://gateway.production.netfoundry.io/core/v2/edge-routers/register/${REG_KEY}"
        elif [[ "${reg_firsttwo}" == "SA" ]]; then
            case "${reg_length}" in
                12) reg_url="https://gateway.sandbox.netfoundry.io/core/v2/edge-routers/register/${REG_KEY}" ;;
                13) reg_url="https://gateway.sandbox.netfoundry.io/core/v3/edge-router-registrations/${REG_KEY}" ;;
                *)  err "Invalid sandbox key length (${reg_length}); expected 12 or 13" ;;
            esac
        elif [[ "${reg_firsttwo}" == "ST" ]]; then
            case "${reg_length}" in
                12) reg_url="https://gateway.staging.netfoundry.io/core/v2/edge-routers/register/${REG_KEY}" ;;
                13) reg_url="https://gateway.staging.netfoundry.io/core/v3/edge-router-registrations/${REG_KEY}" ;;
                *)  err "Invalid staging key length (${reg_length}); expected 12 or 13" ;;
            esac
        else
            err "Unrecognized REG_KEY prefix '${reg_firsttwo}' (length=${reg_length})"
        fi

        reg_response=$(curl -sfk -H "Content-Type: application/json" -X POST "${reg_url}")
        echo "${reg_response}" > reg_response

        jwt=$(jq -r .edgeRouter.jwt               <<< "${reg_response}")
        networkControllerHost=$(jq -r .networkControllerHost <<< "${reg_response}")

        case "${ARCH}" in
            aarch64) upgradelink=$(jq -r .productMetadata.zitiBinaryBundleLinuxARM64 <<< "${reg_response}") ;;
            armv7l)  upgradelink=$(jq -r .productMetadata.zitiBinaryBundleLinuxARM   <<< "${reg_response}") ;;
            *)       upgradelink=$(jq -r .productMetadata.zitiBinaryBundleLinuxAMD64  <<< "${reg_response}") ;;
        esac

        zitiVersion=$(jq -r .productMetadata.zitiVersion <<< "${reg_response}")

        ctrl_rep=$(curl -sf -k \
            "https://${networkControllerHost}:443/edge/client/v1/version" 2>/dev/null || true)
        if jq -e . >/dev/null 2>&1 <<< "${ctrl_rep}"; then
            CONTROLLER_VERSION=$(jq -r .data.version <<< "${ctrl_rep}")
        else
            warn "Could not retrieve controller version during registration"
        fi

        echo "${jwt}" > docker.jwt
        FX_register_router
    fi
else
    if [[ -s "${CERT_FILE}" || -s "${CERT_FILE_OLD}" ]]; then
        log "Cert file found; skipping registration"
    else
        err "REG_KEY is required for initial router registration"
    fi
fi

############### Binary version check / upgrade ###############

# Promote any ziti binary saved in the working dir to the execution path
if [[ ! -f "/opt/openziti/bin/ziti" && -f "ziti" ]]; then
    log "Copying saved ziti binary to /opt/openziti/bin/"
    mkdir -p /opt/openziti/bin
    cp ziti /opt/openziti/bin/
fi

if [[ -f "/opt/openziti/bin/ziti" ]]; then
    ZITI_VERSION=$(/opt/openziti/bin/ziti -v 2>/dev/null)
else
    ZITI_VERSION="Not Found"
fi

log "Router binary version: ${ZITI_VERSION}"

if [[ -n "${ZITI_VERSION_OVERRIDE:-}" ]]; then
    # Pin to an explicit version — bypass controller version check entirely.
    log "ZITI_VERSION_OVERRIDE=${ZITI_VERSION_OVERRIDE} — pinned mode, ignoring controller version"
    if [[ "${ZITI_VERSION}" == "${ZITI_VERSION_OVERRIDE}" ]]; then
        log "Pinned version already installed; no download needed"
    else
        log "Installing pinned version ${ZITI_VERSION_OVERRIDE}..."
        CONTROLLER_VERSION="${ZITI_VERSION_OVERRIDE}"
        FX_upgrade_ziti
        ZITI_VERSION=$(/opt/openziti/bin/ziti -v 2>/dev/null)
    fi
else
    FX_get_controller_version
    if [[ -n "${CONTROLLER_VERSION}" && "${CONTROLLER_VERSION}" == "${ZITI_VERSION}" ]]; then
        log "Versions match; no upgrade needed"
    elif [[ -n "${CONTROLLER_VERSION}" ]]; then
        FX_upgrade_ziti
        ZITI_VERSION=$(/opt/openziti/bin/ziti -v 2>/dev/null)
    fi
fi

############### DNS active flag ###############
# DNS management (config.yml patches + systemd-resolved) requires TUNNEL_MODE=auto.
# In host mode Ziti does not open a DNS port so there is nothing to configure.
# ZITI_DNS_CONFIGURE=false can suppress DNS setup even when TUNNEL_MODE=auto.
# _DNS_ACTIVE itself is set by FX_validate_env.
if [[ "${_DNS_ACTIVE}" == "true" ]]; then
    log "DNS management active (TUNNEL_MODE=auto)"
else
    log "DNS management inactive (TUNNEL_MODE=${AER_TUNNEL_MODE} — only active when TUNNEL_MODE=auto)"
fi

############### Pre-launch: config.yml rendering ###############
# Must run before Ziti starts — ziti reads config.yml once at startup and
# will not pick up changes made after it is already running.

FX_render_config

############### Pre-launch: /etc/hosts injection ###############
# Only active in tunnel mode — in host mode Ziti does not intercept DNS so
# there is no need to pre-seed /etc/hosts to bypass the overlay.

if [[ "${_DNS_ACTIVE}" == "true" && -n "${HOSTS_ENTRIES:-}" ]]; then
    FX_inject_hosts
fi

############### Launch ziti-router ###############

log "Starting ziti-router (version ${ZITI_VERSION})..."

OPS=""
[[ -n "${VERBOSE:-}" ]] && OPS="-v"

/opt/openziti/bin/ziti router run config.yml ${OPS} &
ZITI_PID=$!

# Graceful shutdown: stop ziti, clean up /etc/hosts, exit
trap 'FX_shutdown' TERM INT

############### Startup: stale DNS conf cleanup ###############
# The resolved drop-in lives on the host volume (/etc/systemd:/etc/systemd)
# and survives container restarts.  The sentinel lives in the container's /run/
# and does not.  If a previous container was killed before FX_shutdown could
# clean up, the conf file is left behind but the sentinel is gone — leaving the
# host resolver pointing at a dead Ziti IP.  Detect and remove it now.
if [[ -f "${_RESOLVED_CONF}" && ! -f "${_DNS_CONF_SENTINEL}" ]]; then
    warn "Stale resolved drop-in found (previous container did not clean up); removing..."
    rm -f "${_RESOLVED_CONF}"
    if systemctl restart systemd-resolved 2>/dev/null; then
        ok "systemd-resolved restarted — stale Ziti DNS config cleared"
    else
        warn "Could not restart systemd-resolved — stale config may still be active"
    fi
fi

############### Post-launch: DNS configuration ###############
# Done here (after Ziti starts) so the host DNS is never broken by a config
# that points at Ziti before Ziti's DNS listener is ready.
# In "all" mode FX_configure_ziti_dns will wait for Ziti's DNS port to open
# before touching systemd-resolved.  In "domains" mode it's safe immediately
# since the LAN DNS continues to handle everything else.
if [[ "${_DNS_ACTIVE}" == "true" ]]; then
    FX_configure_ziti_dns &
fi

############### Supervisor loop ###############
# Unified runtime loop — runs in all modes.
#
# Every iteration (60 s) it performs three checks in order:
#
#   1. Version check — skipped when DISABLE_AUTO_UPDATE=true or
#      ZITI_VERSION_OVERRIDE is set.  On mismatch: upgrade binary, restart
#      Ziti, re-apply DNS config.
#
#   2. DNS health check — only active after DNS has been successfully
#      configured (sentinel file present).  On ZITI_DNS_HEALTH_THRSH
#      consecutive failures: revert resolver to host DNS, restart Ziti,
#      re-apply DNS config once Ziti's DNS port is ready again.
#
#   3. Process crash check — if Ziti is not running: revert resolver (so
#      the host is not left pointing at a dead DNS server), restart Ziti,
#      re-apply DNS config.

_DNS_HEALTH_FAILS=0
_dns_check_ip="${ZITI_DNS_IP:-}"
[[ -z "${_dns_check_ip}" ]] && _dns_check_ip=$(SUBFX_dns_detect_lan_ip)

log "Supervisor loop active (interval: 60s)"
while true; do
    # Background sleep + wait so SIGTERM interrupts immediately rather than
    # waiting up to 60 s for sleep to finish.  Without this, bash defers the
    # FX_shutdown trap until after sleep completes, and Docker's default
    # stop timeout (10 s) fires SIGKILL before cleanup ever runs.
    sleep 60 & wait $!

    # ── 1. Version check ───────────────────────────────────────────────────
    if [[ "${DISABLE_AUTO_UPDATE:-}" == "true" ]]; then
        : # static mode — version checks disabled
    elif [[ -n "${ZITI_VERSION_OVERRIDE:-}" ]]; then
        log "ZITI_VERSION_OVERRIDE set — skipping version check"
    else
        FX_get_controller_version
        if [[ -z "${CONTROLLER_VERSION}" ]]; then
            warn "Controller version unavailable; skipping upgrade check"
        elif [[ "${CONTROLLER_VERSION}" != "${ZITI_VERSION}" ]]; then
            log "Version mismatch (router=${ZITI_VERSION}, controller=${CONTROLLER_VERSION}); upgrading..."
            kill "${ZITI_PID}" 2>/dev/null || true
            wait "${ZITI_PID}" 2>/dev/null || true
            FX_upgrade_ziti
            ZITI_VERSION=$(/opt/openziti/bin/ziti -v 2>/dev/null)
            # Re-render: version-gated settings (dnsUpstream list form) must
            # match the binary that is about to start.
            FX_render_config
            log "Restarting ziti-router..."
            /opt/openziti/bin/ziti router run config.yml ${OPS} &
            ZITI_PID=$!
            _DNS_HEALTH_FAILS=0
            if [[ "${_DNS_ACTIVE}" == "true" && -n "${ZITI_DNS_MODE:-}" ]]; then
                FX_configure_ziti_dns &
            fi
            continue
        fi
    fi

    # ── 2. DNS health check ────────────────────────────────────────────────
    # Guard: only run after DNS was successfully configured (sentinel present).
    if [[ "${_DNS_ACTIVE}" == "true" \
          && -n "${ZITI_DNS_MODE:-}" \
          && -f "${_DNS_CONF_SENTINEL}" \
          && -n "${_dns_check_ip}" ]]; then
        if SUBFX_check_ziti_dns "${_dns_check_ip}"; then
            if [[ "${_DNS_HEALTH_FAILS}" -gt 0 ]]; then
                ok "Ziti DNS health restored at ${_dns_check_ip}:53"
                _DNS_HEALTH_FAILS=0
            fi
        else
            _DNS_HEALTH_FAILS=$(( _DNS_HEALTH_FAILS + 1 ))
            warn "Ziti DNS health check failed (${_DNS_HEALTH_FAILS}/${ZITI_DNS_HEALTH_THRSH:-3}) — ${_dns_check_ip}:53 not responding"
            if [[ "${_DNS_HEALTH_FAILS}" -ge "${ZITI_DNS_HEALTH_THRSH:-3}" ]]; then
                warn "Ziti DNS unresponsive — reverting resolver to host DNS and restarting Ziti"
                FX_remove_dns_conf
                kill "${ZITI_PID}" 2>/dev/null || true
                wait "${ZITI_PID}" 2>/dev/null || true
                /opt/openziti/bin/ziti router run config.yml ${OPS} &
                ZITI_PID=$!
                _DNS_HEALTH_FAILS=0
                FX_configure_ziti_dns &
                continue
            fi
        fi
    fi

    # ── 3. Process crash check ─────────────────────────────────────────────
    if ! kill -0 "${ZITI_PID}" 2>/dev/null; then
        warn "ziti process is not running; restarting..."
        if [[ "${_DNS_ACTIVE}" == "true" && -n "${ZITI_DNS_MODE:-}" ]]; then
            FX_remove_dns_conf
        fi
        /opt/openziti/bin/ziti router run config.yml ${OPS} &
        ZITI_PID=$!
        _DNS_HEALTH_FAILS=0
        if [[ "${_DNS_ACTIVE}" == "true" && -n "${ZITI_DNS_MODE:-}" ]]; then
            FX_configure_ziti_dns &
        fi
    fi
done
