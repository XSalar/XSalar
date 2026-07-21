# Runbook

Operational procedures for the Smart DNS nodes.

## Prerequisites

- Two Linux VPS (Debian/Ubuntu), each with a **public IPv4**, ideally in
  different providers/regions. One works to start (no real redundancy).
- On your workstation: `ansible-core`, SSH key access to the node(s) as a
  sudo-capable user.
- Values gathered: `PRIMARY/SECONDARY_VPS_IP`, `*_PUBLIC_IP`, `SSH_USER`,
  `ADMIN_CIDRS`, `HOME_CIDRS`, optional `HOME_DDNS_NAME`.

## First deploy

```bash
cp ansible/inventory.ini.example ansible/inventory.ini
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
# fill in: node IPs (inventory), home_cidrs/admin_cidrs (group_vars)

scripts/deploy.sh check          # dry-run, review the diff
scripts/deploy.sh primary        # deploy node 1
```

The firewall applies with a **120 s auto-revert**. Immediately confirm from a
still-working SSH session:

```bash
sudo /opt/smartdns/scripts/apply-firewall-safe.sh confirm
```

If you get locked out, do nothing — the ruleset reverts automatically after
120 s. Then fix `admin_cidrs` and redeploy.

Deploy the second node the same way: `scripts/deploy.sh secondary`.

## Verify (run from HOME, not the VPS)

```bash
PRIMARY_DNS=x.x.x.x ; PROXY_IP=x.x.x.x
dig @$PRIMARY_DNS www.youtube.com A          # -> PROXY_IP
dig @$PRIMARY_DNS www.youtube.com AAAA       # -> NODATA (empty)
dig @$PRIMARY_DNS www.youtube.com HTTPS      # -> NODATA
dig @$PRIMARY_DNS google.com A               # -> genuine (not PROXY_IP)
dig +tcp @$PRIMARY_DNS youtu.be A            # -> PROXY_IP (TCP path)
openssl s_client -connect $PROXY_IP:443 -servername www.youtube.com </dev/null | head
curl --resolve www.youtube.com:443:$PROXY_IP https://www.youtube.com/ -I
```

Health check on the node:

```bash
sudo PROXY_IP=$PROXY_IP /opt/smartdns/scripts/healthcheck.sh
systemctl list-timers 'smartdns-*'
```

## Managing the target-domain allowlist

Single source of truth: `/etc/dnsdist/domains/{suffixes,exact}.conf`
(from `config/domains/` in this repo). Never edit running config by hand.

```bash
sudo /opt/smartdns/scripts/domains.sh list
sudo /opt/smartdns/scripts/domains.sh add-suffix googlevideo.com
sudo /opt/smartdns/scripts/domains.sh add-exact  yt3.ggpht.com
sudo /opt/smartdns/scripts/domains.sh remove     example.com
sudo /opt/smartdns/scripts/domains.sh validate
sudo /opt/smartdns/scripts/domains.sh reload     # regen nginx map + reload both
```

`reload` regenerates the nginx SNI map and reloads dnsdist + nginx with **no
dropped connections**. To keep the repo authoritative, mirror any change back
into `config/domains/*.conf` and re-run the play.

### Widening the allowlist (only with evidence)

Do **not** add broad Google zones speculatively. If the YouTube app partly
fails, capture the *minimum* extra names, metadata-only, then remove logging:

```bash
# TEMPORARY, on the node, diagnosis only — captures QNAMEs, no payloads:
sudo tcpdump -ni any -s0 'udp port 53 and src <TV_IP>' -w /tmp/dns.pcap
# ...reproduce the failure on the TV, then:
sudo tshark -r /tmp/dns.pcap -T fields -e dns.qry.name | sort -u
sudo rm -f /tmp/dns.pcap        # delete after diagnosis
```

Add only the specific hostnames that appeared and are required, prefer
`add-exact` over broad suffixes. Re-test. See SECURITY.md for why broad
`google.com`/`gstatic.com` proxying is discouraged.

## DDNS (dynamic home IP)

Set `home_ddns_name` in `group_vars/all.yml` and redeploy. The timer
`smartdns-ddns.timer` resolves it via the clean resolver, validates it is a
public IPv4, and atomically updates the `home_v4` nft set. On lookup failure
it **keeps the last good value** and never opens up.

```bash
sudo systemctl start smartdns-ddns.service      # force a run
journalctl -u smartdns-ddns -n 20               # operational status only
sudo nft list set inet smartdns home_v4         # see current allowlist
```

## Reboot / persistence

- All services are `enabled` and restart on failure.
- The firewall persists only **after** you run `apply-firewall-safe.sh
  confirm` (writes `/etc/nftables.conf`, loaded by `nftables.service` at
  boot). Verify: `sudo systemctl is-enabled nftables`.
- After a reboot, re-run the HOME verification block above (test #12).

## Failover behavior (test #13)

The TV uses Primary; if it stops answering, the TV falls back to Secondary.
Failover is TV-driven and can be slow/inconsistent across brands — test it:
stop `dnsdist` on the primary and confirm the TV still resolves/plays via the
secondary.

```bash
# on primary:
sudo systemctl stop dnsdist          # simulate outage
# on TV: YouTube should keep working via Secondary within ~seconds-minutes
sudo systemctl start dnsdist         # restore
```

## Upgrades

```bash
sudo apt update && sudo apt upgrade unbound dnsdist nginx libnginx-mod-stream nftables
sudo /opt/smartdns/scripts/validate-config.sh   # confirm configs still parse
# or simply re-run: scripts/deploy.sh primary   (idempotent)
```

## Backup & restore

- Initial configs are tarred to `/var/backups/smartdns/<timestamp>/` on first
  deploy (pre-existing services included, never overwritten).
- Repo `config/` + `group_vars/all.yml` + `inventory.ini` are the full source
  of truth. Back up the two gitignored files somewhere safe (they hold your
  IPs). Restore = redeploy.
- Roll back configs from a node backup: `sudo /opt/smartdns/scripts/rollback.sh
  restore`.

## Bandwidth / sizing

```bash
scripts/bandwidth-estimate.sh estimate 2 4 1080p   # 2 TVs, 4h/day, 1080p
scripts/bandwidth-estimate.sh probe   $PROXY_IP     # latency + 443 reachability
```

Rules of thumb: 1080p ≈ 4.5 Mbps, 4K ≈ 18 Mbps. Proxied bytes count on the
VPS **twice** (ingress + egress). A “unmetered 1 Gbps / few-TB/month” VPS is
fine for one 1080p TV; sustained 4K for multiple TVs can exceed cheap
allowances — check your provider’s transfer cap before relying on it.

<a id="router-tunnel-fallback"></a>
## Router-tunnel fallback (ONLY if SNI/DPI defeats DNS — needs approval)

If `openssl s_client … -servername www.youtube.com` to your VPS is blocked/
reset from home, DNS is not enough. Proposed design (do **not** deploy without
sign-off):

1. **WireGuard** server on the VPS (`wg0`, e.g. `10.7.0.1/24`, UDP 51820).
2. Home **router** (OpenWrt/Mikrotik/pfSense) runs a WireGuard *client*.
3. **Policy routing**: only the **TV’s LAN IP** is routed into the tunnel
   (`ip rule from <TV_IP> lookup wg`); all other devices route normally.
4. On the VPS, NAT the tunnel egress (`masquerade`) so the TV reaches YouTube
   from the VPS IP — SNI/DPI at the home ISP no longer sees the traffic.
5. Keep the Smart DNS layer for everyone else; the TV uses the tunnel.

Trade-offs: **all** TV traffic (not just YouTube) can traverse the VPS unless
you also split-tunnel by destination; higher bandwidth cost; router must
support WireGuard. This is a separate change with its own runbook — request it
and I’ll provide the full config and tests.
