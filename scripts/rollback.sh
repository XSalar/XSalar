#!/usr/bin/env bash
# =====================================================================
# Full rollback of the Smart DNS node. Restores backed-up configs, and
# either stops the Smart DNS services or removes them entirely. Designed
# to leave any PRE-EXISTING services on the box untouched.
#
#   usage: rollback.sh stop      # stop+disable smart-dns services only
#          rollback.sh restore   # restore configs from the last backup
#          rollback.sh purge      # stop, restore, and remove our files
# =====================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/smartdns}"
SERVICES=(dnsdist nginx unbound smartdns-ddns.timer smartdns-health.timer)

restore_configs() {
  local latest
  latest="$(ls -1d "$BACKUP_DIR"/* 2>/dev/null | sort | tail -1 || true)"
  [[ -n "$latest" ]] || { echo "no backups in $BACKUP_DIR"; return 1; }
  echo "[rollback] restoring from $latest"
  # tar snapshots preserve absolute paths under the backup root.
  if [[ -f "$latest/configs.tar.gz" ]]; then
    tar -xzpf "$latest/configs.tar.gz" -C /
    echo "[rollback] configs restored"
  fi
}

stop_services() {
  for s in "${SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
    echo "[rollback] stopped $s"
  done
  # Restore the firewall snapshot if present (see apply-firewall-safe.sh)
  if [[ -f /var/lib/smartdns/nft-snapshot.rules ]]; then
    nft -f /var/lib/smartdns/nft-snapshot.rules || true
    echo "[rollback] firewall snapshot restored"
  else
    nft flush table inet smartdns 2>/dev/null || true
    nft delete table inet smartdns 2>/dev/null || true
    echo "[rollback] smartdns nft table removed"
  fi
}

case "${1:-}" in
  stop)    stop_services ;;
  restore) restore_configs ;;
  purge)
    stop_services
    restore_configs || true
    rm -f /etc/nginx/stream.d/sni-proxy.conf /etc/nginx/stream.d/sni_allow.map
    rm -rf /etc/dnsdist/domains
    echo "[rollback] smart-dns node files removed; pre-existing services untouched"
    ;;
  *) grep -E '^#|usage:' "$0" | sed -n '3,10p'; exit 1 ;;
esac
echo "[rollback] complete"
