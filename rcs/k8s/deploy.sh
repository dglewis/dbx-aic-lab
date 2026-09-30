#!/usr/bin/env bash
# Create/refresh the credentials Secret from secrets/rcs.env and (re)deploy
# the RCS pod. Usage: rcs/k8s/deploy.sh   (after rcs/k8s/build.sh)
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source secrets/rcs.env; set +a
: "${RCS_IDM_PRINCIPAL:?missing in secrets/rcs.env}" "${RCS_IDM_PASSWORD:?missing in secrets/rcs.env}"

kubectl apply -f rcs/k8s/manifests/rcs.yaml >/dev/null
# Secret content is a JDK @argfile; built from a pipe, never echoed.
printf '%s\n' "-Dconnectorserver.principal=$RCS_IDM_PRINCIPAL" "-Dconnectorserver.password=$RCS_IDM_PASSWORD" \
  | kubectl -n db-conn create secret generic rcs-idm-credentials --from-file=credentials.args=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n db-conn rollout restart statefulset/rcs >/dev/null
kubectl -n db-conn rollout status statefulset/rcs --timeout=180s
