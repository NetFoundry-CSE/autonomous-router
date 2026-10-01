#!/usr/bin/env bash
# tests/render-tests.sh — render matrix for aer-lib.sh.
#
# Run via tests/run.sh, or directly inside the image:
#   docker run --rm -v "$PWD:/w" --entrypoint bash IMAGE /w/tests/render-tests.sh

set -eo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
source "${HERE}/lib.sh"
# shellcheck source=../aer-lib.sh
source "${AER_LIB}"
stub_detect

echo "== Feature 1: tunnel modes"

for m in auto host none AUTO " Host " NoNe ""; do
    reset_env
    [[ -n "${m}" ]] && export TUNNEL_MODE="${m}"
    want="${m//[[:space:]]/}"; want="${want,,}"; want="${want:-host}"
    case_start "mode '${m}'"
    enroll
    check "normalised to ${want}" eq "${AER_TUNNEL_MODE}" "${want}"
    case "${want}" in
        auto) check "argv has --autoTunnelListener" contains "${ENROLL_ARGV}" "--autoTunnelListener"
              check "argv has no --skipDNS" lacks "${ENROLL_ARGV}" "--skipDNS"
              check "binding mode tproxy" eq "$(tunnel .options.mode)" "tproxy" ;;
        host) check "argv has --tunnelListener host" contains "${ENROLL_ARGV}" "--tunnelListener host"
              check "binding mode host" eq "$(tunnel .options.mode)" "host" ;;
        none) check "argv has no tunnel flag" lacks "${ENROLL_ARGV}" "unnelListener"
              check "argv has --skipDNS" contains "${ENROLL_ARGV}" "--skipDNS"
              check "no tunnel binding" eq "$(tunnel)" "null" ;;
    esac
    render
    check "renders" eq "${RC}" 0
    check "DNS active only for auto" eq "$(grep -c 'dnsUpstream' "${AER_CONFIG_FILE}" || true)" "$([[ ${want} == auto ]] && echo 1 || echo 0)"
done

reset_env
for m in tproxy proxy bogus "auto,host"; do
    case_start "mode '${m}'"
    TUNNEL_MODE="${m}" validate
    check "rejected" eq "${RC}" 1
    check "names var + allowed values" contains "${OUT}" "TUNNEL_MODE='${m}' is invalid; allowed values: auto, host, none"
done

# Post-enrollment mode switches, starting from each enrolled mode.
for from in auto host none; do
    for to in auto host none; do
        reset_env
        export TUNNEL_MODE="${from}"
        enroll
        export TUNNEL_MODE="${to}"
        case_start "switch ${from}->${to}"
        render
        check "renders" eq "${RC}" 0
        case "${to}" in
            auto) check "tproxy binding" eq "$(tunnel .options.mode)" "tproxy"
                  check "resolver set" contains "$(tunnel .options.resolver)" "udp://"
                  check "lanIf set" eq "$(tunnel '.options.lanIf | type')" "!!str" ;;
            host) check "host binding" eq "$(tunnel .options.mode)" "host"
                  check "host has no resolver" eq "$(tunnel .options.resolver)" "null" ;;
            none) check "no tunnel binding" eq "$(tunnel)" "null" ;;
        esac
        if [[ "${from}" != "${to}" && "${to}" != "none" ]]; then
            check "tunneler-enabled warning" contains "${OUT}" "must be tunneler-enabled"
        fi
        before=$(md5); render
        check "idempotent" eq "$(md5)" "${before}"
        check "edge listener kept" eq "$(yq '[.listeners[] | select(.binding == "edge")] | length' "${AER_CONFIG_FILE}")" 1
    done
done

reset_env
case_start "none + DNS vars"
export TUNNEL_MODE=none ZITI_DNS_UPSTREAM="1.1.1.1 8.8.8.8" ZITI_DNS_UPSTREAM_MODE=serial ZITI_VERSION=v2.1.0
enroll; render
check "renders" eq "${RC}" 0
check "warns upstream ignored" contains "${OUT}" "ZITI_DNS_UPSTREAM is ignored: TUNNEL_MODE=none"
check "warns mode ignored" contains "${OUT}" "ZITI_DNS_UPSTREAM_MODE is ignored: TUNNEL_MODE=none"
check "no tunnel binding" eq "$(tunnel)" "null"

echo
echo "== Feature 2: dnsUpstream count x router version"

UPSTREAM_SETS=("" "10.0.0.2" "10.0.0.2, 1.1.1.1" "10.0.0.2 1.1.1.1,dns.corp:5353")
UPSTREAM_WANT=("udp://10.20.30.1:53" "udp://10.0.0.2:53"
    "udp://10.0.0.2:53,udp://1.1.1.1:53"
    "udp://10.0.0.2:53,udp://1.1.1.1:53,udp://dns.corp:5353")
for v in v1.7.0 v2.0.0 v2.1.0-pre2 ""; do
    for i in 0 1 2 3; do
        reset_env
        export TUNNEL_MODE=auto ZITI_VERSION="${v}"
        [[ -n "${UPSTREAM_SETS[$i]}" ]] && export ZITI_DNS_UPSTREAM="${UPSTREAM_SETS[$i]}"
        enroll
        case_start "ver '${v:-unknown}' x ${i} upstreams"
        render
        check "renders" eq "${RC}" 0
        want="${UPSTREAM_WANT[$i]}"
        if [[ "${i}" -ge 2 && ( "${v}" == v1.7.0 || -z "${v}" ) ]]; then
            check "scalar first entry" eq "$(tunnel .options.dnsUpstream)" "${want%%,*}"
            check "truncation warning" contains "${OUT}" "dropped: "
            [[ -z "${v}" ]] && check "says version unknown" contains "${OUT}" "could not be determined"
            [[ -n "${v}" ]] && check "says needs >= 2.0.0" contains "${OUT}" "require ziti >= 2.0.0"
        elif [[ "${i}" -ge 2 ]]; then
            check "list form" eq "$(tunnel '.options.dnsUpstream | type')" "!!seq"
            check "order preserved" eq "$(tunnel '.options.dnsUpstream | join(",")')" "${want}"
            check "block style list" contains "$(cat "${AER_CONFIG_FILE}")" "      dnsUpstream:
        - udp://10.0.0.2:53"
        else
            check "scalar" eq "$(tunnel '.options.dnsUpstream | type')" "!!str"
            check "value" eq "$(tunnel .options.dnsUpstream)" "${want}"
        fi
        check "summary line" contains "${OUT}" "Effective settings: tunnel=auto"
        before=$(md5); render
        check "idempotent" eq "$(md5)" "${before}"
    done
done

reset_env
case_start "list -> single on change"
export TUNNEL_MODE=auto ZITI_VERSION=v2.0.0 ZITI_DNS_UPSTREAM="1.1.1.1 8.8.8.8"
enroll; render
export ZITI_DNS_UPSTREAM="9.9.9.9"; render
check "replaced, not appended" eq "$(tunnel .options.dnsUpstream)" "udp://9.9.9.9:53"

case_start "downgrade 2.0 -> 1.7"
export ZITI_DNS_UPSTREAM="1.1.1.1 8.8.8.8"; render
export ZITI_VERSION=v1.7.0; render
check "list collapsed to scalar" eq "$(tunnel .options.dnsUpstream)" "udp://1.1.1.1:53"

reset_env
case_start "normalisation"
export TUNNEL_MODE=auto ZITI_VERSION=v2.0.0
export ZITI_DNS_UPSTREAM=" 1.1.1.1,,udp://1.1.1.1:53 2001:db8::1 [2001:db8::2]:5353 TCP://9.9.9.9:53 dns.corp "
enroll; render
check "normalised + deduped" eq "$(tunnel '.options.dnsUpstream | join(" ")')" \
    "udp://1.1.1.1:53 udp://[2001:db8::1]:53 udp://[2001:db8::2]:5353 tcp://9.9.9.9:53 udp://dns.corp:53"

for bad in "http://1.1.1.1" "999.1.1.1" "dns_server" "1.1.1.1:70000" "[zz::1]"; do
    reset_env
    case_start "upstream '${bad}'"
    TUNNEL_MODE=auto ZITI_DNS_UPSTREAM="1.1.1.1 ${bad}" validate
    check "rejected" eq "${RC}" 1
    check "names var" contains "${OUT}" "ZITI_DNS_UPSTREAM entry '${bad}' is invalid"
done

echo
echo "== Feature 4: dnsUpstreamMode"

for mode in parallel serial failover random SeRiAl; do
    for v in v2.1.0-pre2 v2.0.0 v1.7.0 ""; do
        reset_env
        export TUNNEL_MODE=auto ZITI_VERSION="${v}" ZITI_DNS_UPSTREAM="10.0.0.2 1.1.1.1" ZITI_DNS_UPSTREAM_MODE="${mode}"
        enroll
        case_start "${mode} @ ${v:-unknown}"
        render
        check "renders" eq "${RC}" 0
        case "${v}" in
            v2.1.0-pre2)
                check "emitted lowercased" eq "$(tunnel .options.dnsUpstreamMode)" "${mode,,}"
                check "no <2.1 info" lacks "${OUT}" "takes effect once" ;;
            v2.0.0)
                check "emitted on 2.0" eq "$(tunnel .options.dnsUpstreamMode)" "${mode,,}"
                check "<2.1 info line" contains "${OUT}" "takes effect once the router runs ziti >= 2.1.0" ;;
            *)
                check "not emitted (1 upstream)" eq "$(tunnel .options.dnsUpstreamMode)" "null"
                check "skip info line" contains "${OUT}" "only one dnsUpstream" ;;
        esac
    done
done

reset_env
case_start "mode w/ single upstream"
export TUNNEL_MODE=auto ZITI_VERSION=v2.1.0 ZITI_DNS_UPSTREAM="10.0.0.2" ZITI_DNS_UPSTREAM_MODE=failover
enroll; render
check "not emitted" eq "$(tunnel .options.dnsUpstreamMode)" "null"
check "summary says skipped" contains "${OUT}" "dnsUpstreamMode=failover (skipped, single upstream)"

case_start "mode removed when unset"
export ZITI_DNS_UPSTREAM="10.0.0.2 1.1.1.1"; render
check "emitted" eq "$(tunnel .options.dnsUpstreamMode)" "failover"
unset ZITI_DNS_UPSTREAM_MODE; render
check "removed" eq "$(tunnel .options.dnsUpstreamMode)" "null"

for bad in sequential "serial,failover" round-robin; do
    reset_env
    case_start "mode '${bad}'"
    TUNNEL_MODE=auto ZITI_DNS_UPSTREAM_MODE="${bad}" validate
    check "rejected" eq "${RC}" 1
    check "names var + allowed values" contains "${OUT}" "ZITI_DNS_UPSTREAM_MODE='${bad}' is invalid; allowed values: parallel, serial, failover, random"
done

echo
echo "== Feature 3: link listener"

link_count() { yq '.link.listeners | length' "${AER_CONFIG_FILE}"; }
link() { yq ".link.listeners[0]$1" "${AER_CONFIG_FILE}"; }

# host mode: no DNS patches, so any write would come from the link reconcile.
for adv in 203.0.113.7 er1.example.com; do
    reset_env
    export TUNNEL_MODE=host ZITI_LINK_LISTENER_ENABLED=true ZITI_LINK_ADVERTISE="${adv}"
    case_start "enroll link ${adv}"
    enroll
    check "argv --linkListeners" contains "${ENROLL_ARGV}" "--linkListeners transport tls:0.0.0.0:443 tls:${adv}:443 16"
    check "argv no --assumePublic" lacks "${ENROLL_ARGV}" "assumePublic"
    check "exactly one link listener" eq "$(link_count)" 1
    check "advertise" eq "$(link .advertise)" "tls:${adv}:443"
    check "outQueueSize" eq "$(link .options.outQueueSize)" 16
    check "transport dialer" eq "$(yq '[.link.dialers[] | select(.binding == "transport")] | length' "${AER_CONFIG_FILE}")" 1
    check "advertise in CSR SANs" contains "$(yq '.edge.csr.sans' "${AER_CONFIG_FILE}")" "${adv}"
    before=$(md5); render
    check "renders" eq "${RC}" 0
    check "fresh enrollment not rewritten" eq "$(md5)" "${before}"
    check "summary" contains "${OUT}" "linkAdvertise=tls:${adv}:443"
done

reset_env
case_start "link + ADVERTISE_ADDRESS"
export TUNNEL_MODE=host ADVERTISE_ADDRESS=198.51.100.5:443 ZITI_LINK_LISTENER_ENABLED=true ZITI_LINK_ADVERTISE=203.0.113.7
enroll; render
check "one link listener" eq "$(link_count)" 1
check "our advertise" eq "$(link .advertise)" "tls:203.0.113.7:443"
check "edge advertise" eq "$(yq '.listeners[0].options.advertise' "${AER_CONFIG_FILE}")" "198.51.100.5:443"

reset_env
case_start "enable post-enroll, SAN ok"
export TUNNEL_MODE=auto
enroll
mkcert_sans "DNS:localhost,DNS:er1.example.com,IP:127.0.0.1,IP:203.0.113.7"
export ZITI_LINK_LISTENER_ENABLED=true ZITI_LINK_ADVERTISE=203.0.113.7 ZITI_LINK_ADVERTISE_PORT=8443
render
check "renders" eq "${RC}" 0
check "listener added" eq "$(link .advertise)" "tls:203.0.113.7:8443"
case_start "change to DNS, SAN ok"
export ZITI_LINK_ADVERTISE=ER1.example.com; render
check "renders" eq "${RC}" 0
check "advertise changed" eq "$(link .advertise)" "tls:ER1.example.com:8443"
case_start "change bind/outq only"
export ZITI_LINK_BIND=tls:0.0.0.0:8443 ZITI_LINK_OUTQUEUESIZE=64; render
check "renders" eq "${RC}" 0
check "bind changed" eq "$(link .bind)" "tls:0.0.0.0:8443"
check "outq changed" eq "$(link .options.outQueueSize)" 64
case_start "wildcard SAN"
mkcert_sans "DNS:*.example.com,IP:127.0.0.1"
export ZITI_LINK_ADVERTISE=er2.example.com; render
check "renders" eq "${RC}" 0
check "advertise changed" eq "$(link .advertise)" "tls:er2.example.com:8443"
case_start "wildcard is one label"
export ZITI_LINK_ADVERTISE=a.b.example.com; before=$(md5); render
check "rejected" eq "${RC}" 1
check "config untouched" eq "$(md5)" "${before}"

reset_env
case_start "enable post-enroll, no SAN"
export TUNNEL_MODE=auto
enroll
before=$(md5)
export ZITI_LINK_LISTENER_ENABLED=true ZITI_LINK_ADVERTISE=203.0.113.99
render
check "fails" eq "${RC}" 1
check "says re-enroll" contains "${OUT}" "'203.0.113.99' is not in the router certificate SANs"
check "says re-enrollment" contains "${OUT}" "requires re-enrollment"
check "config untouched" eq "$(md5)" "${before}"

case_start "mode switch + bad SAN"
export TUNNEL_MODE=none
render
check "fails" eq "${RC}" 1
check "tunnel switch not written" eq "$(md5)" "${before}"
check "live config still tproxy" eq "$(tunnel .options.mode)" "tproxy"
export TUNNEL_MODE=auto

case_start "existing, SAN missing"
yq -i '.link.listeners = [{"binding": "transport", "bind": "tls:0.0.0.0:443", "advertise": "tls:203.0.113.99:443", "options": {"outQueueSize": 16}}]' "${AER_CONFIG_FILE}"
render
check "starts" eq "${RC}" 0
check "loud warning" contains "${OUT}" "!!! ZITI_LINK_ADVERTISE: '203.0.113.99' is in config.yml but NOT in the router certificate SANs"

case_start "unset leaves listener"
unset ZITI_LINK_LISTENER_ENABLED ZITI_LINK_ADVERTISE; before=$(md5); render
check "unchanged" eq "$(md5)" "${before}"
check "summary unmanaged" contains "${OUT}" "linkAdvertise=unmanaged"
case_start "false removes listener"
export ZITI_LINK_LISTENER_ENABLED=false; render
check "removed" eq "$(link_count)" 0
check "dialers kept" eq "$(yq '.link.dialers[0].binding' "${AER_CONFIG_FILE}")" "transport"

reset_env
case_start "edge advertise change"
export TUNNEL_MODE=host
enroll
mkcert_sans "DNS:localhost,DNS:edge.example.com,IP:127.0.0.1"
export ADVERTISE_ADDRESS=edge.example.com:8443; render
check "renders" eq "${RC}" 0
check "advertise changed" eq "$(yq '.listeners[0].options.advertise' "${AER_CONFIG_FILE}")" "edge.example.com:8443"
case_start "edge advertise, no SAN"
export ADVERTISE_ADDRESS=other.example.com:443; render
check "fails" eq "${RC}" 1
check "names var" contains "${OUT}" "ADVERTISE_ADDRESS: 'other.example.com' is not in the router certificate SANs"

LINK_BAD=(
    "ZITI_LINK_LISTENER_ENABLED=maybe|ZITI_LINK_LISTENER_ENABLED='maybe' is invalid; allowed values: true, false"
    "ZITI_LINK_LISTENER_ENABLED=true|ZITI_LINK_ADVERTISE is required when ZITI_LINK_LISTENER_ENABLED=true"
    "ZITI_LINK_ADVERTISE=2001:db8::7|IPv6 and HOST:PORT are not supported"
    "ZITI_LINK_ADVERTISE=[2001:db8::7]|IPv6 and HOST:PORT are not supported"
    "ZITI_LINK_ADVERTISE=er1.example.com:443|IPv6 and HOST:PORT are not supported"
    "ZITI_LINK_ADVERTISE=bad_name|ZITI_LINK_ADVERTISE='bad_name' is invalid"
    "ZITI_LINK_ADVERTISE_PORT=0|ZITI_LINK_ADVERTISE_PORT='0' is invalid; allowed values: 1-65535"
    "ZITI_LINK_BIND=0.0.0.0:443|ZITI_LINK_BIND='0.0.0.0:443' is invalid; expected tls:ADDRESS:PORT"
    "ZITI_LINK_OUTQUEUESIZE=-1|ZITI_LINK_OUTQUEUESIZE='-1' is invalid"
    "ADVERTISE_ADDRESS=[2001:db8::1]:443|ADVERTISE_ADDRESS='[2001:db8::1]:443' is invalid"
    "ADVERTISE_ADDRESS=203.0.113.10|ADVERTISE_ADDRESS='203.0.113.10' is invalid"
)
for spec in "${LINK_BAD[@]}"; do
    reset_env
    export TUNNEL_MODE=host ZITI_LINK_ADVERTISE=203.0.113.7
    [[ "${spec}" == ZITI_LINK_LISTENER_ENABLED=maybe* || "${spec}" == ADVERTISE_ADDRESS* ]] || export ZITI_LINK_LISTENER_ENABLED=true
    [[ "${spec}" == "ZITI_LINK_LISTENER_ENABLED=true|"* ]] && unset ZITI_LINK_ADVERTISE
    export "${spec%%|*}"
    case_start "${spec%%|*}"
    validate
    check "rejected" eq "${RC}" 1
    check "message" contains "${OUT}" "${spec#*|}"
done

summary
