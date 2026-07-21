# Tests

Two layers of testing:

1. **`run-local-validation.sh`** — an offline harness that renders the real
   templates and runs unbound + dnsdist + nginx on loopback high-ports, then
   asserts the core behaviours. It proves the **software logic**. It runs
   anywhere the three packages are installed (no VPS, no root-53 needed).
2. **Manual production tests** — run from the **allowlisted home connection**
   and on the **actual TV**. These are the ones that actually certify the
   deployment; the harness cannot substitute for them.

## Run the local harness

```bash
sudo apt-get install -y unbound dnsdist nginx libnginx-mod-stream dnsutils openssl
bash tests/run-local-validation.sh
```

The harness uses a forward-to-8.8.8.8 Unbound (so it works without direct
root egress); production Unbound is full recursion + DNSSEC. It uses the
documentation IP `203.0.113.10` as the stand-in PROXY_IP.

`last-run.log` in this directory is a captured evidence run.

## Coverage map (the 14 required tests)

| # | Requirement | Where |
|---|-------------|-------|
| 1 | Target A → proxy IP | harness **T1** |
| 2 | Target AAAA → no direct IPv6 (NODATA) | harness **T2** |
| 3 | Target HTTPS/SVCB can’t bypass (NODATA) | harness **T3** |
| 4 | Unrelated domain → genuine result | harness **T4** |
| 5 | DNS over UDP **and** TCP | harness **T5** |
| 6 | Unauthorized source can’t use the resolver | harness **T6** (ACL flip) + nftables (prod) |
| 7 | Unauthorized source can’t use the TLS proxy | nftables `home_v4` (prod); app-path shown by T10/T11 |
| 8 | Arbitrary SNI rejected | harness **T8** |
| 9 | Missing / malformed / IP-literal SNI rejected | harness **T9** |
| 10 | Proxy resolves upstream without looping to itself | harness **T10** (uses clean resolver → real IP) |
| 11 | Genuine upstream cert, no TLS warning | harness **T11** (`CN=*.youtube.com`, verify ok) |
| 12 | Survives reboot | prod: services `enabled` + `nftables` persisted — RUNBOOK “Reboot” |
| 13 | Secondary works when primary is down | prod: RUNBOOK “Failover” |
| 14 | Existing services unaffected | prod: backups + non-destructive nginx include — see below |

### What only the production run can prove

- **#6/#7 at the network layer** — the harness proves the *application* ACL
  and SNI allowlist; the *firewall* source-restriction (`home_v4`/`admin_v4`)
  must be checked from a non-home host: `dig @PROXY_IP youtube.com` and
  `openssl s_client -connect PROXY_IP:443 …` should both **time out** from an
  unauthorized source.
- **#11 no-TLS-warning on the TV** — only the real TV client can confirm it
  accepts the origin cert end-to-end.
- **#12 reboot**, **#13 failover**, **#14 no collateral damage** — need the
  live node(s).

### Production quick-checks (copy/paste on the node or from home)

```bash
# From HOME (allowlisted):
dig @PROXY_IP www.youtube.com A ; dig @PROXY_IP www.youtube.com AAAA
dig @PROXY_IP google.com A ; dig +tcp @PROXY_IP youtu.be A
openssl s_client -connect PROXY_IP:443 -servername www.youtube.com </dev/null
openssl s_client -connect PROXY_IP:443 -servername evil.example.org </dev/null  # must fail

# From a NON-home host (should time out — proves firewall #6/#7):
dig @PROXY_IP youtube.com A +time=3

# #14 — confirm we didn't touch other services:
sudo /opt/smartdns/scripts/validate-config.sh
ss -tulpn | grep -E ':53|:80|:443|:853'
```

## Actual-TV checklist (do this last)

Home screen · thumbnails · search · sign-in · video start · seeking · a few
minutes of playback · 1080p · 4K (if needed) · **Primary→Secondary failover**.
