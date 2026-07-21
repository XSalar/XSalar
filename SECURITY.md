# Security model

This is **private household infrastructure**. Its single most important
property: it must **never** become an open resolver or open proxy. Two
independent layers enforce that — the **firewall** (source IP) and the
**application** (dnsdist ACL / nginx SNI allowlist). Either alone is a bug.

## Threat model & non-goals

**In scope**
- Keep the resolver and proxy usable only by *your* home network.
- Preserve end-to-end TLS between the TV and Google (no MITM, ever).
- Avoid leaking the real origin IP for target domains (A rewrite +
  AAAA/HTTPS/SVCB NODATA).
- Survive reboots, transient DDNS lookup failures, and a single-node outage.

**Explicitly NOT goals**
- Anonymity or hiding *that* you use YouTube. Media still flows through your
  VPS; your VPS provider and Google both see it.
- Defeating SNI-based or DPI-based filtering. A TLS pass-through proxy still
  sends the **real SNI** — if the ISP blocks on SNI, this design cannot help
  (see below and README “Is DNS enough?”).
- QUIC/HTTP-3 proxying. Not implemented; UDP/443 is rejected on purpose.

## Layered controls

| Layer | Control | File |
|-------|---------|------|
| Network | Default-deny nftables; 53/443 only from `home_v4`, 22 only from `admin_v4` | `config/nftables/nftables.conf.j2` |
| Network | UDP/443 rejected (QUIC off → TCP fallback) | same |
| Network | Rate limits on 53/443/22 | same |
| App (DNS) | dnsdist `setACL()` from home+admin CIDRs (fail-closed if empty) | `config/dnsdist/dnsdist.conf.j2` |
| App (DNS) | Per-source QPS drop (`MaxQPSIPRule`) | same |
| App (TLS) | nginx SNI allowlist; default-deny; empty upstream ⇒ connection closed | `config/nginx/sni-proxy.conf.j2` |
| App (TLS) | IP-literal / missing / malformed SNI ⇒ rejected | same |
| Resolver | Unbound bound to `127.0.0.1` only, `access-control … refuse` | `config/unbound/unbound.conf.j2` |
| Host | systemd hardening on every unit (NoNewPrivileges, ProtectSystem=strict, cap bounding, MDWX) | ansible roles |
| Secrets | dnsdist console key generated on node, `0600`, never in Git | `roles/dnsdist` |
| Privacy | No query logging; journald retention capped; no third-party telemetry | roles/common + service configs |

## The SNI reality (read this)

nginx `ssl_preread` reads the **cleartext SNI** from the ClientHello to
decide allow/deny. That means:

- **We never decrypt TLS.** Only the SNI hostname (already in the clear on
  the wire) is inspected. The TV validates Google’s real certificate; a
  mismatch would make the TV refuse — which is the correct, safe behavior.
- **The ISP also sees that same SNI.** If your ISP filters on SNI, the
  connection is blocked *before* it reaches your VPS, or is reset even though
  the destination IP is yours. In that case:

  > **DNS-only deployment is not sufficient on this network because the
  > original TLS SNI remains visible. A router-level tunnel for only the TV
  > is required.**

  Verify with `openssl s_client -connect PROXY_IP:443 -servername
  www.youtube.com` from home. The router-tunnel design is in
  [RUNBOOK.md](RUNBOOK.md#router-tunnel-fallback) and is **not deployed
  without approval.**

## IPv6 & HTTPS/SVCB leak prevention

Typing an IPv4 DNS into the TV does **not** disable IPv6. Risks and handling:

- **AAAA on targets → NODATA** (dnsdist), so the TV can’t get a direct IPv6
  route to Google for a proxied name.
- **HTTPS/SVCB (types 65/64) on targets → NODATA**, killing `ipv4hint`,
  `ipv6hint`, ECH config, and h3/QUIC discovery that could bypass the proxy.
- **Residual risk:** if the TV has *native* IPv6 connectivity and a
  hard-coded resolver, it may bypass the IPv4 DNS entirely. Mitigation on the
  home router: disable IPv6 RA/DHCPv6 for the TV, or block the TV’s outbound
  IPv6. This is outside the VPS and must be done at home — documented in the
  RUNBOOK.

## CGNAT caveat (important for allowlisting)

If your home connection is behind **CGNAT** (carrier-grade NAT, e.g. public
IP in `100.64.0.0/10`, or many mobile/ISP setups), your “public IP” is
**shared with other subscribers**. Allowlisting that IP authorizes *all of
them*, not just you. Consequences:

- IP allowlisting is **weak authentication** under CGNAT — treat it as a
  coarse filter, not identity.
- The DDNS updater **refuses** `100.64.0.0/10` addresses as “home” for this
  reason (`is_public_v4` rejects them). If you are truly behind CGNAT you
  cannot use IP allowlisting safely and should use the router-tunnel design
  (WireGuard from the router), where the tunnel key *is* the authentication.

## DNSSEC honesty

Unbound validates DNSSEC for the domains it actually resolves (all
non-target names and the proxy’s own upstream lookups). **Spoofed answers for
target domains are NOT marked AD** — we never label a synthetic answer as
“DNSSEC-authenticated.” Target domains like `youtube.com`/`googlevideo.com`
are not DNSSEC-signed anyway, so no downgrade is introduced for them.

## Reporting / rotating

- Rotate the dnsdist console key: delete `/etc/dnsdist/console.key`, re-run
  the dnsdist role.
- All secrets live outside Git (`.gitignore` covers `.env`, `*.key`,
  inventory, group_vars). Never commit real IPs of your home network if you
  consider them sensitive — keep them in the gitignored files.
