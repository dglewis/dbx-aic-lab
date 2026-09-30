#!/usr/bin/env bash
# Deploy tracked connector config into the (gitignored) IDM runtime:
#   - conf/*.json           -> runtime/openidm/conf/           (hot-reloaded)
#   - script/*.groovy       -> runtime/openidm/script/databricks/
#   - databricks.* substitution values -> resolver/boot.properties
#     (values sourced from secrets/databricks.env; never tracked)
#
# Usage: idm-config/deploy.sh [local|rcs]      (default: local)
#   local — connector in-process in IDM (topology T0)
#   rcs   — connector hosted by the local Java RCS in server mode (T1):
#           adds topology/rcs/*.json, points the provisioner at the RCS
#           (connectorHostRef — &{} isn't allowed in connectorRef, so it is
#           set here) with scriptRoots on the RCS filesystem, and puts
#           rcs.key (secrets/rcs.env) in boot.properties. Deploy the RCS
#           first: rcs/deploy.sh, rcs/run.sh.
# Idempotent — rerun after any config/script/secret change.
set -euo pipefail
cd "$(dirname "$0")/.."

TOPOLOGY="${1:-local}"
case "$TOPOLOGY" in local|rcs) ;; *) echo "usage: $0 [local|rcs]"; exit 2 ;; esac

set -a; source secrets/databricks.env; set +a
: "${DATABRICKS_JDBC_URL:?missing in secrets/databricks.env}"
: "${DATABRICKS_SP_CLIENT_ID:?missing in secrets/databricks.env}"
: "${DATABRICKS_SP_CLIENT_SECRET:?missing in secrets/databricks.env}"

BOOT=runtime/openidm/resolver/boot.properties
[[ -f "$BOOT" ]] || { echo "no $BOOT — is IDM extracted?"; exit 1; }

mkdir -p runtime/openidm/script/databricks
cp idm-config/script/*.groovy runtime/openidm/script/databricks/

# boot.properties: replace-or-append each substitution property.
# The connector authenticates as the service principal (OAuth M2M via the
# customizer); the PAT key is removed so IDM holds no PAT at all — the PAT
# in secrets/ remains only for admin-side lab tooling (apply-sql etc.).
grep -v "^databricks.pat=" "$BOOT" > "$BOOT.tmp" || true; mv "$BOOT.tmp" "$BOOT"
props=("databricks.jdbc.url=${DATABRICKS_JDBC_URL}"
       "databricks.sp.client.id=${DATABRICKS_SP_CLIENT_ID}"
       "databricks.sp.client.secret=${DATABRICKS_SP_CLIENT_SECRET}")
if [[ "$TOPOLOGY" == rcs ]]; then
  set -a; source secrets/rcs.env; set +a
  : "${RCS_KEY:?missing in secrets/rcs.env}"
  props+=("rcs.key=${RCS_KEY}")
fi
for kv in "${props[@]}"; do
  key="${kv%%=*}"
  grep -v "^${key}=" "$BOOT" > "$BOOT.tmp" || true
  printf '%s\n' "$kv" >> "$BOOT.tmp"
  mv "$BOOT.tmp" "$BOOT"
done

# conf last: dropping the provisioner triggers connector activation
CONF=runtime/openidm/conf
if [[ "$TOPOLOGY" == rcs ]]; then
  cp idm-config/topology/rcs/*.json "$CONF/"
  RCS_SCRIPT_ROOT="$PWD/rcs/openicf/scripts/databricks"
  for f in idm-config/conf/*.json; do
    if [[ "$(basename "$f")" == provisioner.openicf-databricks.json ]]; then
      jq --arg root "$RCS_SCRIPT_ROOT" \
        '.connectorRef.connectorHostRef = "rcslocal" | .configurationProperties.scriptRoots = [$root]' \
        "$f" > "$CONF/$(basename "$f")"
    else
      cp "$f" "$CONF/"
    fi
  done
else
  rm -f "$CONF/provisioner.openicf.connectorinfoprovider.json"
  cp idm-config/conf/*.json "$CONF/"
fi

echo "deployed ($TOPOLOGY): $(ls idm-config/conf/*.json | wc -l | tr -d ' ') conf file(s), $(ls idm-config/script/*.groovy | wc -l | tr -d ' ') script(s); boot.properties updated"
