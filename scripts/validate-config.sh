#!/usr/bin/env bash
# Validate all rendered service configs BEFORE (re)starting anything.
# Non-zero exit on any failure. Safe to run in CI.
set -uo pipefail
fail=0
run(){ echo "== $1 =="; shift; if "$@"; then echo "  ok"; else echo "  FAIL"; fail=1; fi; }

DNSDIST_CONF="${DNSDIST_CONF:-/etc/dnsdist/dnsdist.conf}"
UNBOUND_CONF="${UNBOUND_CONF:-/etc/unbound/unbound.conf}"

[[ -f "$DNSDIST_CONF" ]] && run "dnsdist syntax" dnsdist --check-config --config "$DNSDIST_CONF"
[[ -f "$UNBOUND_CONF" ]] && run "unbound syntax" unbound-checkconf "$UNBOUND_CONF"
command -v nginx >/dev/null && run "nginx syntax" nginx -t

echo
[[ $fail -eq 0 ]] && echo "CONFIG OK" || echo "CONFIG INVALID"
exit $fail
