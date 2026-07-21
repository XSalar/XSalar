#!/usr/bin/env bash
# =====================================================================
# Smart DNS node health check. Exit 0 = healthy, non-zero = degraded.
# Safe to run from a systemd timer / external monitor. No secrets, no
# query logging. Uses loopback so it works even behind the firewall.
# =====================================================================
set -uo pipefail

DNS_ADDR="${DNS_ADDR:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-53}"
CLEAN_ADDR="${CLEAN_ADDR:-127.0.0.1}"
CLEAN_PORT="${CLEAN_PORT:-5353}"
PROXY_ADDR="${PROXY_ADDR:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-443}"
PROXY_IP="${PROXY_IP:-}"                 # expected spoof IP for targets
TARGET="${TARGET:-www.youtube.com}"
NEUTRAL="${NEUTRAL:-example.com}"
fail=0
ok(){ echo "  ok   $*"; }
bad(){ echo "  FAIL $*"; fail=1; }

echo "== services =="
for s in unbound dnsdist nginx; do
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$s" && ok "$s active" || bad "$s not active"
  fi
done

echo "== clean resolver ($CLEAN_ADDR:$CLEAN_PORT) =="
dig +short +time=3 +tries=1 @"$CLEAN_ADDR" -p "$CLEAN_PORT" "$NEUTRAL" A | grep -qE '^[0-9]' \
  && ok "resolves $NEUTRAL" || bad "clean resolver not answering"

echo "== smart mapper ($DNS_ADDR:$DNS_PORT) =="
a="$(dig +short +time=3 +tries=1 @"$DNS_ADDR" -p "$DNS_PORT" "$TARGET" A | grep -E '^[0-9]' | head -1)"
if [[ -n "$PROXY_IP" ]]; then
  [[ "$a" == "$PROXY_IP" ]] && ok "$TARGET A -> $a (proxy)" || bad "$TARGET A=$a expected $PROXY_IP"
else
  [[ -n "$a" ]] && ok "$TARGET A -> $a" || bad "$TARGET A empty"
fi
aaaa="$(dig +short +time=3 +tries=1 @"$DNS_ADDR" -p "$DNS_PORT" "$TARGET" AAAA | grep -E '^[0-9a-f]*:' || true)"
[[ -z "$aaaa" ]] && ok "$TARGET AAAA NODATA" || bad "$TARGET leaked AAAA: $aaaa"
neutral="$(dig +short +time=3 +tries=1 @"$DNS_ADDR" -p "$DNS_PORT" "$NEUTRAL" A | grep -E '^[0-9]' | head -1)"
{ [[ -n "$neutral" && "$neutral" != "$PROXY_IP" ]]; } && ok "$NEUTRAL passes through ($neutral)" || bad "$NEUTRAL not genuine ($neutral)"

echo "== TLS proxy ($PROXY_ADDR:$PROXY_PORT) =="
subj="$(echo | timeout 8 openssl s_client -connect "$PROXY_ADDR:$PROXY_PORT" -servername "$TARGET" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
[[ -n "$subj" ]] && ok "allowed SNI handshakes ($subj)" || bad "allowed SNI failed handshake"
# A bogus SNI must be refused (no cert returned).
bogus="$(echo | timeout 8 openssl s_client -connect "$PROXY_ADDR:$PROXY_PORT" -servername not-allowed.example.org 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
[[ -z "$bogus" ]] && ok "bogus SNI rejected" || bad "bogus SNI was proxied!"

echo
[[ $fail -eq 0 ]] && echo "HEALTHY" || echo "DEGRADED"
exit $fail
