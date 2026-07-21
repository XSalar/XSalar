# Smart DNS for Smart TVs (selective YouTube pass-through)

> **Repo note:** `XSalar/XSalar` is your GitHub *profile* repository — its
> `main` branch `README.md` renders on your profile page. This project lives
> on the branch `claude/smart-dns-tv-proxy-onsrau`. **Do not merge this branch
> into `main`** unless you intend to replace your profile README. Keep it on
> the branch, or move it to a dedicated repo.

Private, self-hosted Smart DNS for a household Smart TV that only lets you
type a **Primary** and **Secondary DNS** address. It answers *most* domains
truthfully and, for an **approved YouTube allowlist only**, points the TV at
your own node, which does a **pure TLS SNI pass-through** to the genuine
origin. TLS stays end-to-end (TV ↔ Google). No decryption, no fake certs,
no MITM.

> ⚠️ **This is not a magic bypass.** Changing DNS only defeats *DNS-level*
> interference. If your ISP filters on the TLS **SNI** or does DPI on the
> destination even when it is your VPS, a DNS-only design is **not enough**
> and you need a router-level tunnel for the TV. See
> [“Is DNS enough?”](#is-dns-enough-decide-before-you-trust-it) below.

---

## What this repo is (and is not)

| | |
|---|---|
| ✅ | Validating recursive resolver (Unbound) on `127.0.0.1:5353` |
| ✅ | Smart DNS mapper (dnsdist) on `:53` — spoof A for targets, NODATA for AAAA/HTTPS/SVCB, genuine for everything else |
| ✅ | TLS SNI pass-through proxy (nginx `stream` + `ssl_preread`) on `:443` |
| ✅ | Default-deny nftables firewall, source-allowlisted to your home |
| ✅ | DDNS updater, health checks, systemd hardening, Ansible deploy |
| ✅ | Automated logic tests (see `tests/`) |
| ❌ | An open public resolver or open proxy (it refuses unknown sources/SNI) |
| ❌ | A TLS-terminating / decrypting proxy |
| ❌ | A QUIC/HTTP-3 proxy (UDP/443 is rejected so clients fall back to TCP) |

## Architecture

```
                          YOUR NODE (public IPv4 = PROXY_IP)
  ┌────────┐  DNS :53   ┌──────────────┐  non-target   ┌─────────────────────┐
  │  Smart │──────────▶ │  dnsdist     │──────────────▶│  Unbound (clean)    │
  │  TV    │            │  smart map   │  forward       │  127.0.0.1:5353     │
  │        │◀───────────│              │◀───────────────│  validating + DNSSEC│
  │        │  target A =PROXY_IP        └──────────────┘  qname-min, no ECS   │
  │        │            AAAA/HTTPS = NODATA                └─────────▲─────────┘
  │        │                                                         │ genuine IPs
  │        │  TLS :443  ┌──────────────┐   splice raw TCP  ┌─────────┴─────────┐
  │        │──────────▶ │ nginx stream │──────────────────▶│  real origin      │
  │        │  SNI=      │ ssl_preread  │   (same SNI host) │  (googlevideo…)   │
  │        │  youtube   │ allowlist    │                   └───────────────────┘
  └────────┘            └──────────────┘   TLS stays end-to-end TV↔origin
```

The proxy resolves the **real** upstream through the **clean** resolver
(`:5353`), never through the rewrite layer — so it can never loop back to
itself.

## Redundancy / the two DNS addresses

Your TV wants **Primary** and **Secondary**. Real redundancy needs **two
independent public IPv4 addresses**, ideally two VPS in different providers
/ failure domains. One server with one IP typed twice is **not** redundancy —
if that box or its network dies, the TV loses DNS entirely.

- Fill both nodes into `ansible/inventory.ini` and deploy to both.
- Primary DNS = primary node public IP, Secondary DNS = secondary node
  public IP.
- If you only have one VPS today, deploy the primary and keep the secondary
  config staged; **state clearly that only one DNS address exists** until the
  second node is up.

## Quick start

```bash
# 0. Prereqs on YOUR machine: ansible-core, ssh access to the node(s).
cp .env.example .env                                   # reference only
cp ansible/inventory.ini.example ansible/inventory.ini # fill in real IPs
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml  # home/admin CIDRs
$EDITOR ansible/inventory.ini ansible/group_vars/all.yml

# 1. Dry run, then deploy the primary node
scripts/deploy.sh check
scripts/deploy.sh primary

# 2. The firewall applies with a 120s auto-revert. Reconnect, then on the node:
sudo /opt/smartdns/scripts/apply-firewall-safe.sh confirm

# 3. Verify from HOME (allowlisted), not just from the VPS:
dig @PRIMARY_DNS www.youtube.com A          # -> PROXY_IP
dig @PRIMARY_DNS google.com A               # -> genuine
curl --resolve www.youtube.com:443:PROXY_IP https://www.youtube.com/ -I
```

Then set the TV’s DNS — see **[TV_SETUP_FA.md](TV_SETUP_FA.md)** (Persian).

## Is DNS enough? (decide before you trust it)

Run this from the **home** connection *before* declaring success. Point the
TV’s hostname at your node and watch what the ISP does:

```bash
# Does the ISP block the real SNI even when the IP is YOUR vps?
openssl s_client -connect PROXY_IP:443 -servername www.youtube.com </dev/null
```

- **Handshake completes, real cert** → DNS + SNI pass-through is sufficient. ✅
- **Reset / hang during/after ClientHello** → the ISP is filtering on SNI or
  doing DPI. **A DNS-only solution cannot fix that.** You then need a
  router-level tunnel (WireGuard) applied *only to the TV’s LAN IP*. That
  design is described in [RUNBOOK.md](RUNBOOK.md#router-tunnel-fallback) and
  is **not deployed without your approval.**

Other failure modes to rule out first: transparent port-53 interception
(test `dig @PRIMARY_DNS +tcp`), IPv6 leaking past the IPv4 DNS you typed
(we return NODATA for AAAA on targets, but the TV may still have native IPv6 —
see SECURITY.md), and HTTPS/SVCB records (we NODATA those too).

## Documentation

| File | Purpose |
|------|---------|
| [TV_SETUP_FA.md](TV_SETUP_FA.md) | راهنمای فارسی تنظیم DNS روی تلویزیون |
| [SECURITY.md](SECURITY.md) | Threat model, hardening, CGNAT caveat, IPv6/QUIC honesty |
| [RUNBOOK.md](RUNBOOK.md) | Deploy, operate, widen allowlist, diagnose, router fallback |
| [ROLLBACK.md](ROLLBACK.md) | Undo firewall/config safely without lockout |
| [tests/README.md](tests/README.md) | The 14 required tests + local harness |

## Repository layout

```
ansible/     inventory + site.yml + roles (common,unbound,dnsdist,nginx_sni,nftables,ddns,healthcheck)
config/      single-source templates: domains/, unbound/, dnsdist/, nginx/, nftables/
scripts/     deploy, rollback, healthcheck, domains, ddns-update, safe-firewall, validate, bandwidth
tests/       run-local-validation.sh + render.py + last-run.log (evidence)
```

## Cost warning

Proxied YouTube media flows **through your VPS** and counts against its
transfer allowance (≈ twice, in + out). 1080p ≈ 4.5 Mbps, 4K ≈ 18 Mbps.
Estimate before you commit:

```bash
scripts/bandwidth-estimate.sh estimate 1 3 1080p   # 1 TV, 3h/day, 1080p
```

See [SECURITY.md](SECURITY.md) and RUNBOOK for sizing.
