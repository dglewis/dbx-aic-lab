#!/usr/bin/env bash
# Kill the active RCS pod and record what IDM sees. Two scenarios:
#   ops       — steady connector reads once a second; kill the active pod;
#               measure the error window until rcs1 serves.
#   livesync  — one large Databricks commit (ROWS rows, default 50000) plus a
#               small follow-up commit; start liveSync, kill the active pod
#               while it streams; record the liveSync outcome, the token IDM
#               stored, and what the next liveSync reads.
# Usage: rcs/k8s/failover-test.sh ops|livesync     (topology rcs-k8s, 2 pods)
# Raw log: test/runs/failover-<scenario>-<stamp>.log (gitignored). Test rows
# (record_id FT-*) are deleted at the end.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCENARIO="${1:?usage: $0 ops|livesync}"
ROWS="${ROWS:-50000}"
NS=dbx-aic-lab
IDM=https://localhost:8443/openidm
AUTH=(-u openidm-admin:openidm-admin)
TABLE=workspace.idm_lab.business_records
STAGE=repo/synchronisation/pooledSyncStage/SYSTEMDATABRICKSBUSINESSRECORD

mkdir -p test/runs
LOG="test/runs/failover-$SCENARIO-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "# failover test $SCENARIO $(date -u +%FT%TZ) commit=$(git rev-parse HEAD) rows=$ROWS" > "$LOG"
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
T0=$(now)
log() { printf '%7.1fs  %s\n' "$(python3 -c "print($(now)-$T0)")" "$*" | tee -a "$LOG"; }

set -a; source secrets/databricks.env; set +a
JAVA="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home/bin/java"
dbx() { "$JAVA" -cp runtime/openidm/lib/databricks-jdbc-2.7.3.jar databricks/JdbcRunner.java "$1" 2>&1 \
          | grep -E 'ok \(|ERROR|Exception' | head -2; }
idm() { curl -sk "${AUTH[@]}" -m "${2:-120}" "$@" 2>/dev/null; }
livesync() { curl -sk "${AUTH[@]}" -m 300 -X POST "$IDM/system/databricks/businessRecord?_action=liveSync" -w '\nHTTP %{http_code}'; }
stored_token() { curl -sk "${AUTH[@]}" "$IDM/$STAGE" | jq -r '.connectorData.syncToken'; }
servers() { curl -sk "${AUTH[@]}" -X POST "$IDM/system?_action=testConnectorServers" | jq -c '[.openicf[] | {(.name): .ok}] | add'; }
connector_ok() { curl -sk "${AUTH[@]}" -m 10 -X POST "$IDM/system/databricks?_action=test" | jq -r '.ok' 2>/dev/null; }

# Active pod = first healthy member of the failover group (rcs0, then rcs1).
active_pod() { [[ "$(servers | jq -r '.rcs0')" == true ]] && echo rcs-0 || echo rcs-1; }
kill_pod() { kubectl -n "$NS" delete pod "$1" --grace-period=0 --force >/dev/null 2>&1; log "KILLED $1 (force, no grace)"; }

wait_failover() {   # until the connector answers again, via whichever pod
  local start; start=$(now)
  until [[ "$(connector_ok)" == true ]]; do sleep 0.5; done
  log "connector ok again after $(python3 -c "print(round($(now)-$start,1))")s; servers $(servers)"
}

log "servers $(servers); pods: $(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}')"
[[ "$(connector_ok)" == true ]] || { log "connector not ok before the test — aborting"; exit 1; }
VICTIM=$(active_pod); log "active pod: $VICTIM"

case "$SCENARIO" in
ops)
  ( while :; do
      r=$(curl -sk "${AUTH[@]}" -m 15 -o /dev/null -w '%{http_code} %{time_total}' \
            "$IDM/system/databricks/businessRecord?_queryFilter=true&_pageSize=1" || echo "000 timeout")
      log "read -> $r"; sleep 1
    done ) & READER=$!
  sleep 5; kill_pod "$VICTIM"; wait_failover; sleep 5
  kill "$READER" 2>/dev/null || true
  ;;
livesync)
  log "pre-clean: $(dbx "DELETE FROM $TABLE WHERE record_id LIKE 'FT-%'")"
  log "baseline liveSync: $(livesync | tail -1); stored token $(stored_token) (= B)"
  log "commit B+1, $ROWS rows: $(dbx "INSERT INTO $TABLE SELECT concat('FT-', lpad(cast(id AS STRING), 6, '0')), 'REF-FT', current_timestamp() FROM range($ROWS)")"
  log "commit B+2, 1 row: $(dbx "INSERT INTO $TABLE VALUES ('FT-TAIL', 'REF-FT', current_timestamp())")"
  livesync > "$LOG.ls1" 2>&1 & LS=$!
  log "liveSync started (pid $LS)"
  sleep "${KILL_AFTER:-8}"; kill_pod "$VICTIM"
  wait "$LS" || true
  log "interrupted liveSync -> $(tail -1 "$LOG.ls1"): $(head -c 400 "$LOG.ls1" | tr '\n' ' ')"
  log "stored token after interruption: $(stored_token)"
  wait_failover
  log "next liveSync -> $(livesync | tr '\n' ' ' | head -c 300)"
  log "stored token now: $(stored_token)"
  log "cleanup: $(dbx "DELETE FROM $TABLE WHERE record_id LIKE 'FT-%'")"
  log "post-cleanup liveSync -> $(livesync | tail -1); stored token $(stored_token)"
  rm -f "$LOG.ls1"
  ;;
*) echo "usage: $0 ops|livesync"; exit 2 ;;
esac

log "pods: $(kubectl -n $NS get pods -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}')"
echo "log: $LOG"
