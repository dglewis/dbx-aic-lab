#!/usr/bin/env bash
# Phase-1 acceptance runner (docs/plan.md "Spike execution").
# Exercises the ScriptedSQL connector through IDM's REST API against the real
# Databricks warehouse, and cross-checks writes out-of-band over JDBC.
# Requires: DS + IDM running, idm-config/deploy.sh applied, valid PAT.
set -uo pipefail
cd "$(dirname "$0")/.."

IDM="https://localhost:8443/openidm"
AUTH="-u openidm-admin:openidm-admin"
CURL="curl -sk $AUTH"
SQL=databricks/apply-sql.sh

pass=0; fail=0
check() { # check <name> <haystack> <needle-regex>
  if grep -qE "$3" <<<"$2"; then echo "PASS  $1"; pass=$((pass+1));
  else echo "FAIL  $1"; echo "      got: $(head -c 300 <<<"$2")"; fail=$((fail+1)); fi
}

echo "== 1. connector test"
out=$($CURL --request POST "$IDM/system/databricks?_action=test")
check "system/databricks?_action=test ok" "$out" '"ok" *: *true'

echo "== 2. schema visible (object types exposed)"
out=$($CURL --request POST "$IDM/system?_action=test")
check "objectTypes businessRecord+outboundRecord" "$out" 'businessRecord'

echo "== 3. search / recon source query"
out=$($CURL "$IDM/system/databricks/businessRecord?_queryFilter=true&_pageSize=10")
check "seed rows returned" "$out" 'BR-001'
out=$($CURL "$IDM/system/databricks/businessRecord?_queryFilter=true&_pageSize=2")
check "paging cookie present at pageSize=2" "$out" '"pagedResultsCookie" *: *"'

echo "== 4. create / read / update / delete via IDM, verified in Databricks"
out=$($CURL --request POST -H "Content-Type: application/json" \
  "$IDM/system/databricks/businessRecord?_action=create" \
  -d '{"record_id":"BR-ACC1","ref_id":"REF-ACC"}')
check "create BR-ACC1" "$out" '"_id" *: *"BR-ACC1"'

out=$($CURL "$IDM/system/databricks/businessRecord/BR-ACC1")
check "read-back BR-ACC1" "$out" '"ref_id" *: *"REF-ACC"'

out=$($SQL "SELECT ref_id FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
check "row visible in Databricks" "$out" 'REF-ACC'

out=$($CURL --request PUT -H "Content-Type: application/json" -H "If-Match: *" \
  "$IDM/system/databricks/businessRecord/BR-ACC1" \
  -d '{"record_id":"BR-ACC1","ref_id":"REF-ACC2"}')
check "update ref_id" "$out" '"ref_id" *: *"REF-ACC2"'

out=$($SQL "SELECT ref_id FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
check "update visible in Databricks" "$out" 'REF-ACC2'

out=$($CURL --request DELETE -H "If-Match: *" "$IDM/system/databricks/businessRecord/BR-ACC1")
check "delete BR-ACC1" "$out" '"_id" *: *"BR-ACC1"'

out=$($SQL "SELECT count(*) AS n FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
check "row gone in Databricks" "$out" '(^|[^0-9])0($|[^0-9])'

echo "== 5. liveSync: CDF token advances over out-of-band insert+update+delete"
out=$($CURL --request POST "$IDM/system/databricks/businessRecord?_action=liveSync")
t0=$(sed -n 's/.*"syncToken" *: *\([0-9]*\).*/\1/p' <<<"$out")
$SQL "INSERT INTO workspace.idm_lab.business_records VALUES ('BR-OOB1','REF-OOB',current_timestamp())" \
     "UPDATE workspace.idm_lab.business_records SET ref_id='REF-103', last_modified=current_timestamp() WHERE record_id='BR-001'" \
     "DELETE FROM workspace.idm_lab.business_records WHERE record_id='BR-OOB1'" >/dev/null 2>&1
out=$($CURL --request POST "$IDM/system/databricks/businessRecord?_action=liveSync")
t1=$(sed -n 's/.*"syncToken" *: *\([0-9]*\).*/\1/p' <<<"$out")
echo "      token: ${t0:-?} -> ${t1:-?}"
if [[ -n "${t0:-}" && -n "${t1:-}" && "$t1" -ge $((t0 + 3)) ]]; then
  echo "PASS  liveSync consumed 3 out-of-band commits"; pass=$((pass+1))
else
  echo "FAIL  liveSync token did not advance by 3"; echo "      got: $(head -c 300 <<<"$out")"; fail=$((fail+1))
fi

echo "== 6. outbound object class on the same connector instance"
out=$($CURL "$IDM/system/databricks/outboundRecord?_queryFilter=true&_pageSize=10")
check "outbound seed rows returned" "$out" 'OB-901'
out=$($CURL --request POST -H "Content-Type: application/json" \
  "$IDM/system/databricks/outboundRecord?_action=create" \
  -d '{"record_id":"OB-ACC1","ref_id":"REF-OB"}')
check "outbound create OB-ACC1" "$out" '"_id" *: *"OB-ACC1"'
$CURL --request DELETE -H "If-Match: *" "$IDM/system/databricks/outboundRecord/OB-ACC1" >/dev/null

echo
echo "RESULT: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
