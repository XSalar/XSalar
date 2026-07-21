# Rollback & recovery

Every change here is reversible, and the firewall step is designed so it
**cannot lock you out**. Read this before your first deploy.

## Golden rule: the firewall auto-reverts

`scripts/apply-firewall-safe.sh apply` snapshots the current ruleset and arms
a systemd transient timer that restores it in **120 s**. You must actively
`confirm` to keep the new rules:

```bash
sudo /opt/smartdns/scripts/apply-firewall-safe.sh apply /etc/smartdns-nftables.conf 120
# reconnect / verify SSH still works, THEN:
sudo /opt/smartdns/scripts/apply-firewall-safe.sh confirm
```

If you lose SSH, **do nothing for 120 s** — the old ruleset comes back.

Check the pending revert:

```bash
systemctl list-timers | grep smartdns-fw-revert
systemctl status smartdns-fw-revert.service
```

## Undo the firewall right now

```bash
# restore the pre-change snapshot
sudo nft -f /var/lib/smartdns/nft-snapshot.rules
# or drop just our table (leaves any other tables, e.g. Docker, intact)
sudo nft flush table inet smartdns 2>/dev/null; sudo nft delete table inet smartdns
```

## Stop the Smart DNS services (leave the box otherwise as-is)

```bash
sudo /opt/smartdns/scripts/rollback.sh stop
```
Stops+disables `dnsdist nginx unbound` and the smartdns timers, and restores
the firewall snapshot. Pre-existing services on the box are untouched.

> Note: `nginx` and `unbound` may have existed before this project. `stop`
> disables them; if the box also served other sites via nginx, prefer
> removing only our stream config (below) instead of stopping nginx wholesale.

## Remove only our nginx stream bits (keep an existing nginx)

```bash
sudo rm -f /etc/nginx/stream.d/sni-proxy.conf /etc/nginx/stream.d/sni_allow.map
# remove the block we added (between the SMARTDNS STREAM markers) from nginx.conf
sudo sed -i '/# BEGIN SMARTDNS STREAM/,/# END SMARTDNS STREAM/d' /etc/nginx/nginx.conf
sudo nginx -t && sudo systemctl reload nginx
```

## Restore configs from backup

```bash
sudo /opt/smartdns/scripts/rollback.sh restore     # newest backup
ls -1 /var/backups/smartdns/                        # list available snapshots
```
Backups are created on first deploy and include any pre-existing
`nginx/unbound/dnsdist/nftables` configs, so a restore returns those to their
original content.

## Full purge

```bash
sudo /opt/smartdns/scripts/rollback.sh purge
```
Stops services, restores backed-up configs, and removes our drop-in files and
`/etc/dnsdist/domains`. Packages are left installed (removing them is a manual
`apt purge` if you want).

## Revert the TV

See [TV_SETUP_FA.md](TV_SETUP_FA.md#بازگشت-به-حالت-خودکار-لغو-تنظیمات) —
set DNS back to automatic / DHCP and turn Private DNS back to Automatic.

## Sanity after any rollback

```bash
sudo /opt/smartdns/scripts/healthcheck.sh || echo "expected to fail once stopped"
ss -tulpn | grep -E ':53|:443'      # confirm what is (or isn't) listening
sudo nft list ruleset | head        # confirm firewall state
```
