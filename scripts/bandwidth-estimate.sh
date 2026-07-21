#!/usr/bin/env bash
# Rough monthly egress estimate for proxied YouTube playback, plus a live
# throughput/latency probe you can run FROM HOME toward the proxy IP.
#
#   usage: bandwidth-estimate.sh estimate <tvs> <hours_per_day> <quality>
#          bandwidth-estimate.sh probe    <proxy_ip>
#
# quality: 480p 720p 1080p 1440p 4k   (approx sustained bitrates)
set -euo pipefail

# Approximate YouTube (VP9/AVC) sustained bitrates in Mbps.
declare -A BR=( [480p]=1.1 [720p]=2.5 [1080p]=4.5 [1440p]=9 [4k]=18 )

case "${1:-}" in
  estimate)
    tvs="${2:?tvs}"; hpd="${3:?hours/day}"; q="${4:?quality}"
    mbps="${BR[$q]:?unknown quality: $q}"
    # Mbps * 3600 s = Mb/hour; /8 = MB; *hours*days*tvs; /1000 = GB
    gb=$(awk -v m="$mbps" -v h="$hpd" -v t="$tvs" \
        'BEGIN{ printf "%.0f", (m*3600/8)*h*30*t/1000 }')
    echo "Assumptions: $tvs TV(s), ${hpd}h/day, $q (~${mbps} Mbps), 30 days"
    echo "Estimated ALL-DOWN-THROUGH-PROXY egress: ~${gb} GB / month"
    echo "NOTE: proxied traffic is counted TWICE on the VPS (in + out)."
    echo "      Budget ~2x this against the VPS transfer allowance."
    ;;
  probe)
    ip="${2:?proxy ip}"
    echo "== latency =="; ping -c 5 -W 2 "$ip" 2>/dev/null | tail -2 || echo "ping blocked"
    echo "== TCP 443 reachability =="
    if timeout 6 bash -c ">/dev/tcp/$ip/443" 2>/dev/null; then echo "  443 open"; else echo "  443 unreachable"; fi
    echo "== throughput (needs a byte source on the node; see RUNBOOK) =="
    echo "  run: iperf3 -c $ip   (if you deploy iperf3 temporarily)"
    ;;
  *) grep -E '^#|usage:' "$0" | sed -n '2,9p'; exit 1 ;;
esac
