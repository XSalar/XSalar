#!/usr/bin/env bash
# =====================================================================
# LOCAL LOGIC VALIDATION HARNESS  (loopback only — NOT a production test)
# ---------------------------------------------------------------------
# Renders the real templates and runs unbound + dnsdist + nginx on
# loopback high-ports, then exercises the 14 behaviours from the spec.
# It proves the SOFTWARE LOGIC (DNS rewrite, NODATA rules, SNI allow/deny,
# no-loop upstream resolution, real cert pass-through). It CANNOT prove
# anything about the production VPS, the ISP path, or the actual TV —
# those require the live nodes and a test from the home connection.
#
# Requires: unbound, dnsdist, nginx (+stream), dig, openssl, python3.
# Ports: unbound 5353, dnsdist 5300, nginx-sni 8443  (all 127.0.0.1).
# =====================================================================
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/smartdns-val.XXXXXX)"
PROXY_IP="203.0.113.10"          # TEST-DACT placeholder (documentation IP)
UB_PORT=5353; DD_PORT=5300; NGX_PORT=8443
pass=0; fail=0
PASS(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
FAIL(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
INFO(){ printf '  ---- %s\n' "$*"; }

cleanup(){
  [[ -f "$W/unbound.pid" ]] && kill "$(cat "$W/unbound.pid")" 2>/dev/null
  [[ -f "$W/dnsdist.pid" ]] && kill "$(cat "$W/dnsdist.pid")" 2>/dev/null
  [[ -f "$W/nginx.pid"   ]] && kill "$(cat "$W/nginx.pid")"   2>/dev/null
  sleep 0.3
}
trap cleanup EXIT
echo "workdir: $W"

# ---------------------------------------------------------------------
# 1. Render + start the CLEAN resolver (test uses forward-to-8.8.8.8 so
#    it works without direct root egress; production is full recursion).
# ---------------------------------------------------------------------
mkdir -p "$W/ub.d"
cat > "$W/ub.d/forward.conf" <<'EOF'
forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 1.1.1.1
EOF
python3 "$REPO/tests/render.py" "$REPO/config/unbound/unbound.conf.j2" \
    unbound_listen=127.0.0.1 unbound_port=$UB_PORT unbound_do_ip6=no \
    unbound_trust_anchor="$W/root.key" unbound_threads=1 \
    unbound_dropin_glob="$W/ub.d/*.conf" > "$W/unbound.conf"
# Neutralise DNSSEC anchor + syslog for the sandbox run.
sed -i '/auto-trust-anchor-file/d; s/use-syslog: yes/use-syslog: no/' "$W/unbound.conf"
unbound-checkconf "$W/unbound.conf" >/dev/null && INFO "unbound config valid"
unbound -d -c "$W/unbound.conf" >"$W/unbound.log" 2>&1 &
echo $! > "$W/unbound.pid"; sleep 1.2

# ---------------------------------------------------------------------
# 2. Render + start the SMART MAPPER (dnsdist) on loopback high port.
# ---------------------------------------------------------------------
mkdir -p "$W/domains"
cp "$REPO/config/domains/suffixes.conf" "$W/domains/suffixes.conf"
cp "$REPO/config/domains/exact.conf"    "$W/domains/exact.conf"
python3 "$REPO/tests/render.py" "$REPO/config/dnsdist/dnsdist.conf.j2" \
    dns_listen="127.0.0.1:$DD_PORT" \
    dnsdist_acl_csv="127.0.0.0/8, ::1/128" \
    upstream="127.0.0.1:$UB_PORT" \
    dnsdist_console_key="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)" \
    qps_limit=200 proxy_ip="$PROXY_IP" > "$W/dnsdist.conf"
# Point the domain-list loader at our workdir copies for the test.
sed -i "s#/etc/dnsdist/domains#$W/domains#g" "$W/dnsdist.conf"
dnsdist --check-config --config "$W/dnsdist.conf" >/dev/null 2>&1 && INFO "dnsdist config valid"
dnsdist --supervised --disable-syslog --config "$W/dnsdist.conf" >"$W/dnsdist.log" 2>&1 &
echo $! > "$W/dnsdist.pid"; sleep 1.2

# ---------------------------------------------------------------------
# 3. Render + start the nginx SNI proxy on loopback high port.
# ---------------------------------------------------------------------
bash "$REPO/scripts/gen-nginx-map.sh" \
    "$W/domains/suffixes.conf" "$W/domains/exact.conf" "$W/sni_allow.map" >/dev/null
python3 "$REPO/tests/render.py" "$REPO/config/nginx/sni-proxy.conf.j2" \
    proxy_listen="127.0.0.1:$NGX_PORT" resolver_addr="127.0.0.1:$UB_PORT" \
    sni_map_path="$W/sni_allow.map" connect_timeout=10s idle_timeout=120s \
    proxy_error_log="$W/nginx-sni-error.log" > "$W/sni-proxy.conf"
STREAM_MOD="$(find /usr/lib/nginx/modules -name ngx_stream_module.so | head -1)"
cat > "$W/nginx.conf" <<EOF
load_module $STREAM_MOD;
worker_processes 1;
pid $W/nginx.pid;
events { worker_connections 256; }
error_log $W/nginx-main-error.log error;
stream {
    include $W/sni-proxy.conf;
}
EOF
nginx -t -c "$W/nginx.conf" >>"$W/nginx-main-error.log" 2>&1 && INFO "nginx config valid"
nginx -c "$W/nginx.conf" &
sleep 1.0

echo; echo "================ RUNNING TESTS ================"

dq(){ dig +time=3 +tries=1 "$@"; }

# T1: target A -> proxy IP
a="$(dq @127.0.0.1 -p $DD_PORT www.youtube.com A +short | grep -E '^[0-9]' | head -1)"
[[ "$a" == "$PROXY_IP" ]] && PASS "T1 target A -> proxy IP ($a)" || FAIL "T1 target A=$a expected $PROXY_IP"

# T2: target AAAA -> NODATA (no direct IPv6)
aaaa="$(dq @127.0.0.1 -p $DD_PORT www.youtube.com AAAA +short | grep -E ':' || true)"
st="$(dq @127.0.0.1 -p $DD_PORT www.youtube.com AAAA | grep -E 'status:' | grep -o 'status: [A-Z]*')"
[[ -z "$aaaa" ]] && PASS "T2 target AAAA NODATA ($st)" || FAIL "T2 leaked AAAA: $aaaa"

# T3: target HTTPS/SVCB -> NODATA (no SVCB hint bypass)
https="$(dq @127.0.0.1 -p $DD_PORT www.youtube.com HTTPS +short || true)"
[[ -z "$https" ]] && PASS "T3 target HTTPS/SVCB NODATA" || FAIL "T3 HTTPS record leaked: $https"

# T4: unrelated domain -> genuine result (not proxy IP)
n="$(dq @127.0.0.1 -p $DD_PORT example.com A +short | grep -E '^[0-9]' | head -1)"
{ [[ -n "$n" && "$n" != "$PROXY_IP" ]]; } && PASS "T4 neutral genuine ($n)" || FAIL "T4 neutral wrong ($n)"

# T5: works over UDP and TCP
u="$(dq @127.0.0.1 -p $DD_PORT youtu.be A +short | head -1)"
t="$(dq +tcp @127.0.0.1 -p $DD_PORT youtu.be A +short | head -1)"
{ [[ "$u" == "$PROXY_IP" && "$t" == "$PROXY_IP" ]]; } && PASS "T5 UDP+TCP both work" || FAIL "T5 udp=$u tcp=$t"

# T6: unauthorized source cannot use the resolver (flip ACL to a network
#     that does NOT include loopback; the instance must START and then
#     REFUSE our loopback query — proving it's the ACL, not a dead process).
sed -e "s#127.0.0.0/8, ::1/128#10.99.0.0/16#" \
    -e 's#127.0.0.1:5199#127.0.0.1:5198#' "$W/dnsdist.conf" > "$W/dnsdist-acl.conf"
dnsdist --supervised --disable-syslog --config "$W/dnsdist-acl.conf" \
    --local 127.0.0.1:5301 >"$W/dnsdist-acl.log" 2>&1 &
aclpid=$!; sleep 1.2
if kill -0 "$aclpid" 2>/dev/null && ss -lun 2>/dev/null | grep -q '127.0.0.1:5301'; then
  refused="$(dq @127.0.0.1 -p 5301 www.youtube.com A 2>&1 | grep -Eo 'REFUSED|timed out|no servers could be reached' | head -1 || true)"
  [[ -n "$refused" ]] && PASS "T6 off-ACL source blocked, instance live ($refused)" \
    || FAIL "T6 off-ACL source got an answer"
else
  FAIL "T6 ACL-test instance failed to start (cannot assert ACL)"
fi
kill $aclpid 2>/dev/null

# T8/T9: arbitrary + missing/malformed SNI rejected by proxy
allowed_subj="$(echo | timeout 8 openssl s_client -connect 127.0.0.1:$NGX_PORT -servername www.youtube.com 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
bogus_subj="$(echo | timeout 8 openssl s_client -connect 127.0.0.1:$NGX_PORT -servername evil.example.org 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
nosni_out="$(echo | timeout 8 openssl s_client -connect 127.0.0.1:$NGX_PORT 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
iplit_out="$(echo | timeout 8 openssl s_client -connect 127.0.0.1:$NGX_PORT -servername 8.8.8.8 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
[[ -z "$bogus_subj" ]] && PASS "T8 arbitrary SNI rejected" || FAIL "T8 arbitrary SNI proxied: $bogus_subj"
{ [[ -z "$nosni_out" && -z "$iplit_out" ]]; } && PASS "T9 missing/IP-literal SNI rejected" || FAIL "T9 nosni='$nosni_out' iplit='$iplit_out'"

# T7 + T10 + T11: allowed SNI is proxied to the GENUINE origin (real cert),
#   proving upstream is resolved via the clean resolver (no self-loop) and
#   TLS stays end-to-end. (T7 unauthorized-source is a firewall test; here
#   we confirm the app-layer allow path produces a real origin cert.)
if [[ "$allowed_subj" == *youtube.com* ]]; then
  PASS "T10+T11 allowed SNI -> genuine origin cert ($allowed_subj)"
else
  FAIL "T10+T11 allowed SNI did not yield youtube cert (subj='$allowed_subj') — upstream 443 may be blocked in this sandbox"
fi

# Config-syntax gates (feed into T12/T14 confidence)
nft -c -f <(python3 "$REPO/tests/render.py" "$REPO/config/nftables/nftables.conf.j2" \
    home_v4_elements="203.0.113.0/24" admin_v4_elements="198.51.100.7/32" \
    ssh_port=22 ssh_rate="10/minute" dns_rate="50/second" conn_rate="30/second" \
    2>/dev/null) 2>/dev/null && PASS "nftables ruleset syntactically valid" \
    || FAIL "nftables ruleset failed nft -c"

echo; echo "================ RESULT ================"
echo "PASS=$pass FAIL=$fail"
echo "logs in $W (unbound.log, dnsdist.log, nginx-*.log)"
[[ $fail -eq 0 ]] && echo "LOCAL VALIDATION: ALL GREEN" || echo "LOCAL VALIDATION: FAILURES PRESENT"
exit $fail
