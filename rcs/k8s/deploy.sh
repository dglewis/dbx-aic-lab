#!/usr/bin/env bash
# Create/refresh the credentials Secret from secrets/rcs.env and (re)deploy
# the Databricks RCS cluster. Usage: rcs/k8s/deploy.sh   (after rcs/k8s/build.sh)
# One login per connector server: the Secret holds one JDK @argfile per
# server (<server>.args: principal <server>-client, RCS_IDM_PASSWORD_<SERVER>).
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source secrets/rcs.env; set +a
NS=dbx-aic-lab
SERVERS=(databricks0 databricks1)   # must match the StatefulSet's replicas

kubectl apply -f rcs/k8s/manifests/databricks.yaml >/dev/null
# Secret content built from a pipe of temp files in a private dir, never echoed.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; chmod 700 "$tmp"
args=()
for srv in "${SERVERS[@]}"; do
  var="RCS_IDM_PASSWORD_$(echo "$srv" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${!var:-}" ]] || { echo "missing $var in secrets/rcs.env"; exit 1; }
  printf '%s\n' "-Dconnectorserver.principal=${srv}-client" "-Dconnectorserver.password=${!var}" > "$tmp/$srv.args"
  args+=(--from-file="$srv.args=$tmp/$srv.args")
done
kubectl -n "$NS" create secret generic databricks-rcs-credentials "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Retire the pre-ADR-003 objects (StatefulSet "rcs", shared-login Secret).
kubectl -n "$NS" delete statefulset/rcs pdb/rcs secret/rcs-idm-credentials --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NS" rollout restart statefulset/databricks >/dev/null
kubectl -n "$NS" rollout status statefulset/databricks --timeout=240s
