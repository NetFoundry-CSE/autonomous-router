# NetFoundry Autonomous Edge Router

A containerized [NetFoundry](https://netfoundry.io) / OpenZiti Edge Router that self-registers, manages its own DNS, and optionally self-updates — all from a single `compose.yml`.

---

## Requirements

- Docker + Docker Compose v2
- Ubuntu 22.04 or 24.04 (host)
- A NetFoundry registration key

**One-time host prep:**
```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo chmod 755 /etc/systemd/resolved.conf.d
```

---

## Quick Start

**1. Clone the repo**
```bash
git clone https://github.com/nicfragale/autonomous-router.git
cd autonomous-router
```

**2. Create a `.env` file**
```bash
cp .env.example .env
```

Edit `.env` and set your registration key:
```env
REG_KEY=your-netfoundry-registration-key
```

**3. Start the router**
```bash
docker compose up -d
```

On first run the router will register with NetFoundry using your `REG_KEY`, download its identity and certificates, and start automatically. Subsequent restarts skip registration.

**4. Check the logs**
```bash
docker compose logs -f
```

---

## Configuration

All settings are controlled via environment variables in your `.env` file. The compose file provides defaults for everything except `REG_KEY`.

### General

| Variable | Default | Description |
|---|---|---|
| `ZITI_CONTAINER_NAME` | `autonomous-router` | Docker container name. Set this in your `.env` to give the container a custom name. |
| `REG_KEY` | *(required on first run)* | NetFoundry registration key. Ignored once `certs/cert.pem` exists. |
| `TUNNEL_MODE` | `auto` (compose) / `host` (unset) | `auto`, `host` or `none`, case-insensitive. Applied to `config.yml` on every start, so it can be changed without re-registering. Any other value stops the container. See [Tunnel modes](#tunnel-modes). |
| `VERBOSE` | *(unset)* | Set to any non-empty value to pass `-v` to `ziti router run`. |
| `HTTPS_PROXY` | *(unset)* | Proxy URL for outbound connections e.g. `http://proxy.corp:3128`. |
| `ADVERTISE_ADDRESS` | *(unset)* | Override the advertised edge listener address. Required when the host's public IP differs from its LAN IP. Format: `HOST:PORT` with an IPv4 address or DNS name, e.g. `203.0.113.10:443`. Applied on every start; after enrollment the host must already be in the router certificate (see [Certificates and re-enrollment](#certificates-and-re-enrollment)). |

### Update Control

| Variable | Default | Description |
|---|---|---|
| `DISABLE_AUTO_UPDATE` | `false` | Set to `true` to skip controller-version checks entirely. Ziti starts once and runs until the container stops. The crash-restart supervisor still runs. |
| `ZITI_VERSION_OVERRIDE` | *(unset)* | Pin the router binary to a specific version, bypassing all version-match checks. Format: `vMAJOR.MINOR.PATCH` e.g. `v1.7.2`. Setting both this and `DISABLE_AUTO_UPDATE=true` gives a fully static, no-loop deployment. |

### DNS Setup (`ZITI_DNS_CONFIGURE=true`)

| Variable | Default | Description |
|---|---|---|
| `ZITI_DNS_CONFIGURE` | `true` | Set to `true` to enable DNS setup at startup. Writes a systemd-resolved drop-in and restarts resolved. Requires the `systemd` volume mounts below. |
| `ZITI_DNS_MODE` | `all` | `all` — route **every** DNS query through Ziti DNS (recommended). `domains` — route only the domains listed in `ZITI_DNS_DOMAINS`. |
| `ZITI_DNS_DOMAINS` | *(unset)* | Space-separated list of domains to route through Ziti DNS. Only used when `ZITI_DNS_MODE=domains`. e.g. `lan ziti corp internal`. |
| `ZITI_DNS_IP` | *(auto-detected)* | IP address of the Ziti DNS server. Auto-detected from the host's default LAN route when unset. |
| `ZITI_DNS_FALLBACK` | *(unset)* | Fallback resolver written into the systemd-resolved drop-in for queries Ziti DNS cannot answer. Auto-detected from the host's current resolver when unset. |
| `ZITI_DNS_DISABLE_MDNS` | `false` | Set to `true` to add `MulticastDNS=no` to the resolved drop-in. Required when your DNS server serves `.local` records — without this, systemd-resolved intercepts `.local` on the mDNS stack (RFC 6762) before the query ever reaches Ziti DNS, returning SERVFAIL. |
| `ZITI_DNS_WAIT_TIMEOUT` | `60` | Seconds to wait for Ziti DNS to become reachable after Ziti starts. Increase if your controller is slow to provision the DNS listener. |
| `ZITI_DNS_HEALTH_THRSH` | `3` | Consecutive failed DNS probes before the resolver reverts to host DNS and Ziti is restarted. Each probe runs once per supervisor loop iteration (~60 s), so the default triggers after ~3 min of unresponsive Ziti DNS. |

### Ziti Config Patches (`ZITI_DNS_CONFIGURE=true`)

| Variable | Default | Description |
|---|---|---|
| `ZITI_DNS_RANGE` | *(unset)* | CIDR written into `config.yml` as `dnsSvcIpRange` (overlay service address pool). If unset will default to `100.64.0.0/10`. |
| `ZITI_DNS_UPSTREAM` | *(auto-detected)* | One or more upstream resolvers written into `config.yml` as `dnsUpstream` (used by the Ziti DNS server for non-overlay lookups). Auto-detected from the host's current resolver when unset (same source as `ZITI_DNS_FALLBACK`, formatted as `udp://IP:53`). See [Multiple DNS upstreams](#multiple-dns-upstreams). |
| `ZITI_DNS_UPSTREAM_MODE` | *(unset)* | `parallel`, `serial`, `failover` or `random`. How Ziti queries multiple upstreams. See [DNS upstream query mode](#dns-upstream-query-mode). |

### Hosts Injection

| Variable | Default | Description |
|---|---|---|
| `HOSTS_ENTRIES` | `INTERFACE_ASSIGNED` | Static records injected into `/etc/hosts` before Ziti starts. Resolved locally by the OS — never forwarded to the overlay. Separated by semicolons or newlines. Block is removed automatically on container shutdown. To modify the **host's** `/etc/hosts` (not just the container's), add `- /etc/hosts:/etc/hosts` to your compose volumes. |

**Supported `HOSTS_ENTRIES` formats:**

| Format | Example | Behavior |
|---|---|---|
| IP + hostname | `192.168.1.10 db.internal alias` | Written as-is |
| Hostname only | `myhost.corp` | Forward DNS lookup before Ziti starts; resolved IP is written |
| IP only | `10.20.30.84` | Reverse PTR lookup; all PTR records written as aliases |
| `INTERFACE_ASSIGNED` | *(default)* | Auto-detects host LAN IP at runtime, then reverse-lookups it |

---

## Tunnel modes

`TUNNEL_MODE` picks what kind of tunnel binding the router gets:

| Value | Tunnel binding | Ziti DNS server | Use it for |
|---|---|---|---|
| `auto` | `tproxy` on the default-route interface | yes | Intercepting traffic and DNS on this host |
| `host` | `host` | no | Hosting services only (default when unset) |
| `none` | none | no | A plain edge/fabric router with no tunneler |

Matching is case-insensitive, and the value is checked on every start. Anything else stops the container with an error.

The mode is applied to `config.yml` on every start. Switching modes on an enrolled router rewrites the tunnel binding to the shape `ziti_router_auto_enroll` would have produced, with no re-registration needed. Switching to `auto` or `host` only carries traffic if the router is tunneler-enabled on the controller (NetFoundry console). The AER cannot check or change that setting.

With `none`:
- no `--autoTunnelListener` or `--tunnelListener` is passed at enrollment, and `--skipDNS` is added;
- DNS management, the systemd-resolved drop-in, and `HOSTS_ENTRIES` injection are skipped;
- `ZITI_DNS_UPSTREAM` and `ZITI_DNS_UPSTREAM_MODE` are ignored, with a warning;
- `cap_add: NET_ADMIN`, `pid: host`, and the `/etc/systemd`, `/run/systemd` and `/etc/hosts` mounts are no longer needed. They are harmless to leave in place.

```yaml
    environment:
      - TUNNEL_MODE=none
```

---

## Multiple DNS upstreams

`ZITI_DNS_UPSTREAM` takes a comma- and/or space-separated list. Order matters for the `serial` and `failover` query modes.

| Entry | Written as |
|---|---|
| `10.0.0.2`, `dns.corp` | `udp://10.0.0.2:53`, `udp://dns.corp:53` |
| `10.0.0.2:5353` | `udp://10.0.0.2:5353` |
| `2001:db8::1`, `[2001:db8::1]:5353` | `udp://[2001:db8::1]:53`, `udp://[2001:db8::1]:5353` |
| `udp://…`, `tcp://…` | unchanged |

Empty entries are dropped, duplicates are removed with order kept, and any other scheme or malformed host stops the container.

ziti 1.x only accepts a single string for `dnsUpstream` and treats a list as a fatal config error. The AER reads the installed binary's version (`ziti -v`) before rendering:

- **ziti ≥ 2.0.0:** two or more upstreams are written as a YAML list.
- **ziti < 2.0.0, or version unknown:** only the first entry is written, as a string, and a warning names the dropped entries.
- **One entry:** always a string, exactly as before.

`config.yml` is re-rendered before ziti restarts after an auto-upgrade, so the form always matches the binary that runs.

```yaml
    environment:
      - TUNNEL_MODE=auto
      - ZITI_DNS_UPSTREAM=10.0.0.2, 1.1.1.1
```

---

## DNS upstream query mode

`ZITI_DNS_UPSTREAM_MODE` sets `dnsUpstreamMode` on the tunnel binding:

| Value | Behavior (ziti ≥ 2.1.0) |
|---|---|
| `parallel` | Query all upstreams at once; first `NOERROR` wins (the 2.0 behavior and ziti's default) |
| `serial` | Try upstreams in the configured order, always from the first |
| `failover` | Like `serial`, but start from the upstream that last answered `NOERROR` |
| `random` | Like `serial`, starting from a random upstream |

The value is case-insensitive and checked at startup. ziti 2.1 treats an invalid value as a fatal config error, so a typo stops the container here before it can stop the router.

The key is written only when `TUNNEL_MODE=auto`, DNS management is on, and at least two upstreams are left after the version check. It is not version-gated: ziti 2.0.x ignores unknown tunnel options, so writing it there is harmless, and the log notes that it takes effect from 2.1.0. Unsetting the variable removes the key.

```yaml
    environment:
      - TUNNEL_MODE=auto
      - ZITI_DNS_UPSTREAM=10.0.0.2, 10.0.0.3, 1.1.1.1
      - ZITI_DNS_UPSTREAM_MODE=failover
```

---

## Fabric link listener

By default the router only dials links to other routers. A link listener lets other routers dial it.

| Variable | Default | Description |
|---|---|---|
| `ZITI_LINK_LISTENER_ENABLED` | *(unset)* | `true` adds one `transport` link listener. `false` removes any link listener. Unset leaves `config.yml` as it is. |
| `ZITI_LINK_ADVERTISE` | *(none)* | **Required when enabled.** Public IPv4 address or DNS name other routers will dial. IPv6 is not supported (the enrollment script cannot put an IPv6 literal in the certificate). |
| `ZITI_LINK_ADVERTISE_PORT` | `443` | Port in the advertised address. |
| `ZITI_LINK_BIND` | `tls:0.0.0.0:443` | Local bind. Sharing 443 with the edge listener works through ALPN (ziti ≥ 0.30). |
| `ZITI_LINK_OUTQUEUESIZE` | `16` | Link listener `outQueueSize`. |

At enrollment the AER passes `--linkListeners transport <bind> tls:<advertise>:<port> <outqueuesize>`, so the advertise host goes into the router certificate. The rendered config keeps the default `transport` link dialer.

The router has to be reachable at the advertise address and port from the other routers: inbound firewall rules, cloud security groups, and any NAT port-forward. The compose file uses `network_mode: host`, so nothing needs to be published. With bridge networking, publish the bind port; 443 is already published for the edge listener.

```yaml
    environment:
      - ZITI_LINK_LISTENER_ENABLED=true
      - ZITI_LINK_ADVERTISE=er1.example.com
```

---

## Certificates and re-enrollment

Registration (`ziti_router_auto_enroll`) only runs when there is no router certificate yet. After that, the AER applies the env to `config.yml` on every start: tunnel mode, DNS options, `ADVERTISE_ADDRESS` and the link listener.

Advertised addresses are the one thing the certificate limits. Edge and link listeners present `certs/server_cert.pem`, and its SANs were fixed at enrollment. So on every start, for `ADVERTISE_ADDRESS` and `ZITI_LINK_ADVERTISE`:

- **Host already in the certificate:** the change is applied. Ports, binds and queue sizes can always change.
- **Host not in the certificate, and the change would add it to `config.yml`:** startup stops with an error that says re-enrollment is required. `config.yml` is left untouched.
- **Host already in `config.yml` but missing from the certificate:** startup continues, with a loud warning.

To re-enroll, stop the container, move `./ziti_router` aside, get a new registration key from the NetFoundry console, and start again with the new `REG_KEY` and the advertise settings you want.

Leaving `ADVERTISE_ADDRESS` or `ZITI_LINK_LISTENER_ENABLED` unset never touches those listeners. That way a DHCP address change on the host can't force a re-enrollment.

**Behavior change:** before this version `ADVERTISE_ADDRESS` was ignored after enrollment. A router whose `ADVERTISE_ADDRESS` has since been edited will now apply it on restart, or stop if the new host is not in its certificate.

---

## Version compatibility

| Feature | Minimum ziti version | On older versions |
|---|---|---|
| Multiple `ZITI_DNS_UPSTREAM` entries | 2.0.0 | First entry only, with a warning |
| `ZITI_DNS_UPSTREAM_MODE` | 2.1.0 | Written but ignored by 2.0.x; not written for < 2.0.0 (single upstream) |
| Link listener sharing port 443 with the edge listener | 0.30 | Use a separate `ZITI_LINK_BIND` port |

---

## Testing

The render logic lives in `aer-lib.sh`, so it can be tested without enrolling a router:

```bash
tests/run.sh
```

This builds the image locally and runs two suites in throwaway containers:

- `tests/render-tests.sh` — every tunnel mode and mode switch; 0–3 upstreams against ziti 1.7.0, 2.0.0, v2.1.0-pre2 and an unknown version; each upstream mode plus invalid values; link listener on and off with IPv4, IPv6 (rejected) and DNS advertise values; and the certificate SAN checks. Enrollment is simulated with `ziti_router_auto_enroll --printConfig` and a self-signed certificate.
- `tests/compat-diff.sh` — renders the auto_enroll command line and `config.yml` with the previous entrypoint (`main` by default; set `BASE_REF` to change it) and with this one, for representative `auto` and `host` env sets that use none of the new variables. Both must be byte-identical.

---

## DNS Behavior

With default settings, **all DNS on the host** is routed through the Ziti DNS server:

```
Host process
    └── nsswitch (checks /etc/hosts first)
          └── systemd-resolved → Ziti DNS server
                ├── Overlay record?  → returns overlay IP  (traffic tunnels through Ziti)
                ├── Unknown record?  → forwards to 1.1.1.1 (traffic exits normally)
                └── Unreachable?     → falls back to ZITI_DNS_FALLBACK
```

`.local` queries bypass the mDNS stack and flow through Ziti DNS as well (`ZITI_DNS_DISABLE_MDNS=true`).

---

## Stopping & Cleanup

```bash
# Stop the router (graceful 30s shutdown)
docker compose down
```

On shutdown the entrypoint automatically:
- Stops the Ziti process
- Removes the systemd-resolved drop-in config
- Restarts systemd-resolved to restore original DNS

Router identity and certs are persisted in `./ziti_router` and survive restarts.

---

## Image

Published to GitHub Container Registry:
```
ghcr.io/nicfragale/autonomous-router:latest
```



---

### Startup & DNS Flow

![Autonomous Edge Router Flow](flow.jpg)
