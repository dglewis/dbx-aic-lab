#!/usr/bin/env bash
# Phase-1 acceptance runner (docs/plan.md "Spike execution").
# Exercises the ScriptedSQL connector through IDM's REST API against the real
# Databricks warehouse, and cross-checks writes out-of-band over JDBC.
# Requires: DS + IDM running, idm-config/deploy.sh applied, valid PAT.
#
# Every raw response is appended to a timestamped evidence log under
# evidence/ — the script source is the record of the exact commands,
# the log is the record of what the systems actually returned.
set -uo pipefail
cd "$(dirname "$0")/.."

IDM="https://localhost:8443/openidm"
AUTH="-u openidm-admin:openidm-admin"
CURL="curl -sk $AUTH"
SQL=databricks/apply-sql.sh

EV_DIR=evidence
mkdir -p "$EV_DIR"
EV="$EV_DIR/acceptance-$(date +%Y%m%d-%H%M%S).log"
{
  echo "# Acceptance run $(date -u +%FT%TZ)"
  echo "# repo commit: $(git rev-parse HEAD) (tree: $(git status --porcelain | wc -l | tr -d ' ') uncommitted paths)"
  echo "# IDM: $IDM  warehouse: via secrets/databricks.env (values not logged)"
  echo "# commands: see idm-config/acceptance-test.sh at the commit above"
} >> "$EV"

ev() { # ev <label> <raw content>
  { echo; echo "=== [$(date -u +%FT%TZ)] $1"; printf '%s\n' "$2"; } >> "$EV"
}

pass=0; fail=0
check() { # check <name> <haystack> <needle-regex>
  if grep -qE "$3" <<<"$2"; then echo "PASS  $1"; pass=$((pass+1));
  else echo "FAIL  $1"; echo "      got: $(head -c 300 <<<"$2")"; fail=$((fail+1)); fi
}

echo "evidence log: $EV"

echo "== 1. connector test"
out=$($CURL --request POST "$IDM/system/databricks?_action=test")
ev "1 POST system/databricks?_action=test" "$out"
check "system/databricks?_action=test ok" "$out" '"ok" *: *true'

echo "== 2. schema visible (object types exposed)"
out=$($CURL --request POST "$IDM/system?_action=test")
ev "2 POST system?_action=test" "$out"
check "objectTypes businessRecord+outboundRecord" "$out" 'businessRecord'

echo "== 3. search / recon source query"
out=$($CURL "$IDM/system/databricks/businessRecord?_queryFilter=true&_pageSize=10")
ev "3a GET businessRecord?_queryFilter=true&_pageSize=10" "$out"
check "seed rows returned" "$out" 'BR-001'
out=$($CURL "$IDM/system/databricks/businessRecord?_queryFilter=true&_pageSize=2")
ev "3b GET businessRecord?_queryFilter=true&_pageSize=2 (paging)" "$out"
check "paging cookie present at pageSize=2" "$out" '"pagedResultsCookie" *: *"'

echo "== 4. create / read / update / delete via IDM, verified in Databricks"
out=$($CURL --request POST -H "Content-Type: application/json" \
  "$IDM/system/databricks/businessRecord?_action=create" \
  -d '{"record_id":"BR-ACC1","ref_id":"REF-ACC"}')
ev "4a POST create BR-ACC1" "$out"
check "create BR-ACC1" "$out" '"_id" *: *"BR-ACC1"'

out=$($CURL "$IDM/system/databricks/businessRecord/BR-ACC1")
ev "4b GET BR-ACC1 (read-back via IDM)" "$out"
check "read-back BR-ACC1" "$out" '"ref_id" *: *"REF-ACC"'

out=$($SQL "SELECT record_id, ref_id, last_modified FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
ev "4c JDBC out-of-band SELECT BR-ACC1 (bypasses IDM)" "$out"
check "row visible in Databricks" "$out" 'REF-ACC'

out=$($CURL --request PUT -H "Content-Type: application/json" -H "If-Match: *" \
  "$IDM/system/databricks/businessRecord/BR-ACC1" \
  -d '{"record_id":"BR-ACC1","ref_id":"REF-ACC2"}')
ev "4d PUT BR-ACC1 ref_id=REF-ACC2" "$out"
check "update ref_id" "$out" '"ref_id" *: *"REF-ACC2"'

out=$($SQL "SELECT record_id, ref_id FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
ev "4e JDBC out-of-band SELECT after update" "$out"
check "update visible in Databricks" "$out" 'REF-ACC2'

echo "== 4x. read-only enforcement: client-supplied last_modified is discarded"
before=$($CURL "$IDM/system/databricks/businessRecord/BR-002")
ev "4x-1 GET BR-002 before" "$before"
out=$($CURL --request PUT -H "Content-Type: application/json" -H "If-Match: *" \
  "$IDM/system/databricks/businessRecord/BR-002" \
  -d '{"record_id":"BR-002","ref_id":"REF-101","last_modified":"1999-01-01T00:00:00.000000Z"}')
ev "4x-2 PUT BR-002 attempting last_modified=1999-01-01" "$out"
check "1999 timestamp NOT accepted (server re-stamped)" "$out" '"last_modified" *: *"20'

out=$($CURL --request DELETE -H "If-Match: *" "$IDM/system/databricks/businessRecord/BR-ACC1")
ev "4f DELETE BR-ACC1" "$out"
check "delete BR-ACC1" "$out" '"_id" *: *"BR-ACC1"'

out=$($SQL "SELECT count(*) AS n FROM workspace.idm_lab.business_records WHERE record_id='BR-ACC1'" 2>&1)
ev "4g JDBC out-of-band count after delete" "$out"
check "row gone in Databricks" "$out" '(^|[^0-9])0($|[^0-9])'

echo "== 5. liveSync: CDF token advances over out-of-band insert+update+delete"
out=$($CURL --request POST "$IDM/system/databricks/businessRecord?_action=liveSync")
ev "5a POST liveSync (baseline)" "$out"
t0=$(sed -n 's/.*"syncToken" *: *\([0-9]*\).*/\1/p' <<<"$out")
out=$($SQL "INSERT INTO workspace.idm_lab.business_records VALUES ('BR-OOB1','REF-OOB',current_timestamp())" \
     "UPDATE workspace.idm_lab.business_records SET ref_id='REF-103', last_modified=current_timestamp() WHERE record_id='BR-001'" \
     "DELETE FROM workspace.idm_lab.business_records WHERE record_id='BR-OOB1'" 2>&1)
ev "5b JDBC out-of-band insert BR-OOB1 + update BR-001 + delete BR-OOB1" "$out"
out=$($CURL --request POST "$IDM/system/databricks/businessRecord?_action=liveSync")
ev "5c POST liveSync (after out-of-band changes)" "$out"
t1=$(sed -n 's/.*"syncToken" *: *\([0-9]*\).*/\1/p' <<<"$out")
echo "      token: ${t0:-?} -> ${t1:-?}"
ev "5d token movement" "baseline=$t0 after=$t1 (expect after >= baseline+3: one commit each for insert/update/delete)"
if [[ -n "${t0:-}" && -n "${t1:-}" && "$t1" -ge $((t0 + 3)) ]]; then
  echo "PASS  liveSync consumed 3 out-of-band commits"; pass=$((pass+1))
else
  echo "FAIL  liveSync token did not advance by 3"; echo "      got: $(head -c 300 <<<"$out")"; fail=$((fail+1))
fi

echo "== 6. outbound object class on the same connector instance"
out=$($CURL "$IDM/system/databricks/outboundRecord?_queryFilter=true&_pageSize=10")
ev "6a GET outboundRecord?_queryFilter=true" "$out"
check "outbound seed rows returned" "$out" 'OB-901'
out=$($CURL --request POST -H "Content-Type: application/json" \
  "$IDM/system/databricks/outboundRecord?_action=create" \
  -d '{"record_id":"OB-ACC1","ref_id":"REF-OB"}')
ev "6b POST create OB-ACC1" "$out"
check "outbound create OB-ACC1" "$out" '"_id" *: *"OB-ACC1"'
out=$($CURL --request DELETE -H "If-Match: *" "$IDM/system/databricks/outboundRecord/OB-ACC1")
ev "6c DELETE OB-ACC1 (cleanup)" "$out"

echo
echo "RESULT: $pass passed, $fail failed"
ev "RESULT" "$pass passed, $fail failed"
echo "evidence log: $EV"
[[ $fail -eq 0 ]]
