#!/usr/bin/env bash
# =====================================================================
# Apply an nftables ruleset WITH an automatic revert, so a mistake can
# never lock you out of SSH. Sequence:
#   1. snapshot current ruleset
#   2. arm a revert that fires in $GRACE seconds
#   3. load the new ruleset
#   4. YOU reconnect / confirm within the grace window
#   5. run this script with `confirm` to cancel the revert & persist
#
#   usage: apply-firewall-safe.sh apply   <ruleset.nft>   [grace_seconds]
#          apply-firewall-safe.sh confirm
# =====================================================================
set -euo pipefail

SNAP="/var/lib/smartdns/nft-snapshot.rules"
PERSIST="/etc/nftables.conf"
GRACE="${3:-120}"
mkdir -p /var/lib/smartdns

case "${1:-}" in
  apply)
    RULESET="${2:?path to new ruleset}"
    echo "[fw] snapshotting current ruleset -> $SNAP"
    nft list ruleset > "$SNAP"

    echo "[fw] arming auto-revert in ${GRACE}s (systemd-run transient timer)"
    systemd-run --unit=smartdns-fw-revert --on-active="${GRACE}" \
      /usr/sbin/nft -f "$SNAP" >/dev/null

    echo "[fw] validating new ruleset"
    nft -c -f "$RULESET"

    echo "[fw] loading new ruleset"
    nft -f "$RULESET"

    cat <<EOF

  >>> New firewall is LIVE. Auto-revert fires in ${GRACE}s. <<<
  If you can still reach SSH, run:

      $(readlink -f "$0") confirm

  to CANCEL the revert and persist the ruleset. If you do nothing,
  the old ruleset is restored automatically.
EOF
    ;;

  confirm)
    echo "[fw] cancelling auto-revert"
    systemctl stop smartdns-fw-revert.timer 2>/dev/null || true
    systemctl reset-failed smartdns-fw-revert.service 2>/dev/null || true
    echo "[fw] persisting ruleset -> $PERSIST"
    nft list ruleset > "$PERSIST"
    chmod 0640 "$PERSIST"
    echo "[fw] done. Firewall persisted and will load on boot."
    ;;

  *)
    grep -E '^#|usage:' "$0" | sed -n '3,14p'
    exit 1 ;;
esac
