#!/usr/bin/env bash
# =====================================================================
# DDNS -> nftables allowlist updater  (fail-closed)
# ---------------------------------------------------------------------
# Resolves HOME_DDNS_NAME through the CLEAN local resolver, validates the
# result is a legitimate PUBLIC IPv4, and atomically updates the nft set
# `home_v4`. On any failure it KEEPS the last known good address and
# never widens access. Records operational status only (no query data).
#
# Driven by a systemd timer (see ansible/roles/ddns).
# =====================================================================
set -euo pipefail

DDNS_NAME="${HOME_DDNS_NAME:-}"
RESOLVER="${CLEAN_RESOLVER:-127.0.0.1}"
RESOLVER_PORT="${CLEAN_RESOLVER_PORT:-5353}"
NFT_TABLE="${NFT_TABLE:-inet smartdns}"
NFT_SET="${NFT_SET:-home_v4}"
PREFIX="${HOME_PREFIX:-/32}"          # allowlist a single host by default
STATE="${DDNS_STATE:-/var/lib/smartdns/ddns.last}"
EXTRA_HOME_CIDRS="${EXTRA_HOME_CIDRS:-}"   # always-present static homes

log() { logger -t smartdns-ddns "$*" 2>/dev/null || true; echo "[ddns] $*"; }

[[ -n "$DDNS_NAME" ]] || { log "no HOME_DDNS_NAME set; nothing to do"; exit 0; }
mkdir -p "$(dirname "$STATE")"

# --- Is this a real, routable, public IPv4? ---
is_public_v4() {
  local ip="$1" o1 o2
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  IFS=. read -r o1 o2 _ _ <<<"$ip"
  (( o1<=255 && o2<=255 )) || return 1
  case "$o1" in 0|10|127) return 1;; esac
  case "$ip" in
    169.254.*) return 1;;                       # link-local
    192.168.*) return 1;;                       # RFC1918
    255.255.255.255) return 1;;
  esac
  (( o1==172 && o2>=16 && o2<=31 )) && return 1 # RFC1918
  (( o1==100 && o2>=64 && o2<=127 )) && return 1 # CGNAT 100.64/10 (see SECURITY.md)
  (( o1>=224 )) && return 1                      # multicast/reserved
  return 0
}

# --- Resolve via the CLEAN resolver only ---
new_ip="$(dig +short +time=3 +tries=2 @"$RESOLVER" -p "$RESOLVER_PORT" "$DDNS_NAME" A 2>/dev/null \
          | grep -E '^[0-9]+\.' | head -1 || true)"

if [[ -z "$new_ip" ]] || ! is_public_v4 "$new_ip"; then
  if [[ -s "$STATE" ]]; then
    log "lookup failed or non-public ('${new_ip:-none}') — KEEPING last good $(cat "$STATE")"
    exit 0
  fi
  log "lookup failed and no prior state — failing CLOSED (set left unchanged)"
  exit 1
fi

last="$(cat "$STATE" 2>/dev/null || true)"
if [[ "$new_ip" == "$last" ]]; then
  exit 0   # no change, stay quiet
fi

# --- Atomically rebuild the set: new home IP + any static extras ---
elements="${new_ip}${PREFIX}"
if [[ -n "$EXTRA_HOME_CIDRS" ]]; then
  elements="$elements, ${EXTRA_HOME_CIDRS//,/, }"
fi

# flush + add inside one `nft -f` transaction == atomic swap.
nft -f - <<EOF
flush set ${NFT_TABLE} ${NFT_SET}
add element ${NFT_TABLE} ${NFT_SET} { ${elements} }
EOF

printf '%s' "$new_ip" > "$STATE"
log "updated ${NFT_SET}: ${last:-none} -> ${new_ip} (elements: ${elements})"
