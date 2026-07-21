#!/usr/bin/env bash
# =====================================================================
# Manage the Smart DNS target-domain allowlist safely, without a rebuild.
#
#   domains.sh list
#   domains.sh add-suffix <domain>
#   domains.sh add-exact  <domain>
#   domains.sh remove     <domain>          # removes from both lists
#   domains.sh validate                     # syntax check only
#   domains.sh reload                       # regenerate + reload services
#
# After add/remove this regenerates the nginx map and reloads dnsdist +
# nginx. dnsdist re-reads the domain files on reload; nginx reloads the
# generated map. Neither service is restarted (no dropped connections).
# =====================================================================
set -euo pipefail

# Locations (overridable via env for the local test harness).
DOMAINS_DIR="${DOMAINS_DIR:-/etc/dnsdist/domains}"
SUFFIXES="${SUFFIXES:-$DOMAINS_DIR/suffixes.conf}"
EXACT="${EXACT:-$DOMAINS_DIR/exact.conf}"
NGINX_MAP="${NGINX_MAP:-/etc/nginx/stream.d/sni_allow.map}"
GEN="$(dirname "$0")/gen-nginx-map.sh"

valid_host() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; }

require_host() {
  [[ -n "${1:-}" ]] || { echo "error: domain required" >&2; exit 1; }
  valid_host "$1" || { echo "error: invalid domain '$1'" >&2; exit 1; }
  # Guardrail: refuse to proxy entire broad Google zones by accident.
  case "$1" in
    google.com|googleapis.com|gstatic.com|googleusercontent.com|ggpht.com)
      echo "refused: '$1' is too broad — add a specific subdomain with evidence (see RUNBOOK.md)" >&2
      exit 1;;
  esac
}

add_to() {  # add_to <file> <domain>
  local f="$1" d="$2"
  grep -qxF "$d" "$f" 2>/dev/null && { echo "already present: $d"; return 0; }
  printf '%s\n' "$d" >> "$f"
  echo "added $d -> $(basename "$f")"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    echo "# suffixes ($SUFFIXES):";  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$SUFFIXES"
    echo "# exact    ($EXACT):";     sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$EXACT"
    ;;
  add-suffix) require_host "${1:-}"; add_to "$SUFFIXES" "$1"; "$0" reload ;;
  add-exact)  require_host "${1:-}"; add_to "$EXACT"    "$1"; "$0" reload ;;
  remove)
    d="${1:?domain required}"
    for f in "$SUFFIXES" "$EXACT"; do
      if grep -qxF "$d" "$f" 2>/dev/null; then
        grep -vxF "$d" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        echo "removed $d from $(basename "$f")"
      fi
    done
    "$0" reload ;;
  validate)
    bash "$GEN" "$SUFFIXES" "$EXACT" "$(mktemp)" >/dev/null
    echo "OK: domain lists are valid"
    ;;
  reload)
    bash "$GEN" "$SUFFIXES" "$EXACT" "$NGINX_MAP"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload dnsdist 2>/dev/null || systemctl restart dnsdist
      nginx -t && systemctl reload nginx
    else
      echo "(no systemd here — regenerated map only)"
    fi
    echo "reload complete"
    ;;
  *)
    grep -E '^#|domains.sh' "$0" | sed -n '3,12p'
    exit 1 ;;
esac
