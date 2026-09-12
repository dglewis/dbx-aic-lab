#!/usr/bin/env bash
# Token-lifetime soak (design.md migration checklist step 6): query the
# connector every INTERVAL for COUNT iterations, crossing the 1-hour OAuth
# token boundary. Pool maxAge=50min recycles connections before their
# token expires; driver M2M auto-refresh is undocumented, so this observes
# the behavior instead of assuming it.
#   usage: databricks/soak-test.sh [count=9] [interval_seconds=600]
set -uo pipefail
cd "$(dirname "$0")/.."

COUNT="${1:-9}"; INTERVAL="${2:-600}"
EV="evidence/soak-$(date +%Y%m%d-%H%M%S).log"
echo "# M2M token-lifetime soak: $COUNT probes @ ${INTERVAL}s ($(date -u +%FT%TZ))" | tee "$EV"

fails=0
for i in $(seq 1 "$COUNT"); do
  [[ $i -gt 1 ]] && sleep "$INTERVAL"
  out=$(curl -sk -u openidm-admin:openidm-admin \
    "https://localhost:8443/openidm/system/databricks/businessRecord?_queryFilter=true&_pageSize=1")
  if grep -q '"resultCount"' <<<"$out"; then status=OK; else status=FAIL; fails=$((fails+1)); fi
  line="[$(date -u +%FT%TZ)] probe $i/$COUNT: $status $(head -c 160 <<<"$out")"
  echo "$line" | tee -a "$EV"
done

echo "# soak result: $((COUNT-fails))/$COUNT ok ($(date -u +%FT%TZ))" | tee -a "$EV"
[[ $fails -eq 0 ]]
