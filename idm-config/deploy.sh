#!/usr/bin/env bash
# Deploy tracked connector config into the (gitignored) IDM runtime:
#   - conf/*.json           -> runtime/openidm/conf/           (hot-reloaded)
#   - script/*.groovy       -> runtime/openidm/script/databricks/
#   - databricks.* substitution values -> resolver/boot.properties
#     (values sourced from secrets/databricks.env; never tracked)
#
# Usage: idm-config/deploy.sh [local|rcs-client|rcs-k8s|rcs]      (default: local)
#   local      — connector in-process in IDM (topology T0)
#   rcs-client — connector hosted by the local Java RCS in client mode (T2,
#                the target — AIC supports only client mode): adds
#                topology/rcs-client/*.json; the RCS "rcslocal" connects in to
#                IDM's /openicf as `rcslocal-client`.
#   rcs-k8s    — as rcs-client, but the RCS runs as pods (T3): servers
#                databricks0 and databricks1 in the failover group "databricks"
#                (topology/rcs-k8s/); scriptRoots is the path inside the image
#                (/opt/openicf/scripts/databricks).
#   Client mode: one login per connector server (Ping's recommendation) — a
#   STATIC_USER `<server>-client` whose only role, `<server>-client-authorized`,
#   may connect only as <server>; password rcs.idm.password.<server> in
#   boot.properties from RCS_IDM_PASSWORD_<SERVER> (secrets/rcs.env; all
#   servers are written, so only adding a server needs an IDM restart).
#                Deploy the pods first: rcs/k8s/build.sh, rcs/k8s/deploy.sh.
#   rcs        — stepping stone only: RCS in server mode (T1):
#           adds topology/rcs/*.json, points the provisioner at the RCS
#           (connectorHostRef — &{} isn't allowed in connectorRef, so it is
#           set here) with scriptRoots on the RCS filesystem, and puts
#           rcs.key (secrets/rcs.env) in boot.properties. Deploy the RCS
#           first: rcs/deploy.sh, rcs/run.sh.
# Idempotent — rerun after any config/script/secret change.
set -euo pipefail
cd "$(dirname "$0")/.."

TOPOLOGY="${1:-local}"
case "$TOPOLOGY" in local|rcs|rcs-client|rcs-k8s) ;; *) echo "usage: $0 [local|rcs-client|rcs-k8s|rcs]"; exit 2 ;; esac
CLIENT_MODE=false; [[ "$TOPOLOGY" == rcs-client || "$TOPOLOGY" == rcs-k8s ]] && CLIENT_MODE=true

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
grep -v -E "^(databricks\.pat|rcs\.idm\.password(\.[a-z0-9]+)?)=" "$BOOT" > "$BOOT.tmp" || true; mv "$BOOT.tmp" "$BOOT"
props=("databricks.jdbc.url=${DATABRICKS_JDBC_URL}"
       "databricks.sp.client.id=${DATABRICKS_SP_CLIENT_ID}"
       "databricks.sp.client.secret=${DATABRICKS_SP_CLIENT_SECRET}")
if [[ "$TOPOLOGY" == rcs ]]; then
  set -a; source secrets/rcs.env; set +a
  : "${RCS_KEY:?missing in secrets/rcs.env}"
  props+=("rcs.key=${RCS_KEY}")
elif $CLIENT_MODE; then
  set -a; source secrets/rcs.env; set +a
  # Every server's password, whatever the topology: IDM reads boot.properties
  # only at startup, so switching topology then needs no restart.
  for srv in $(jq -r '.[].properties.username | sub("-client$"; "")' "idm-config/topology/$TOPOLOGY/auth-modules.json"); do
    var="RCS_IDM_PASSWORD_$(echo "$srv" | tr '[:lower:]' '[:upper:]')"
    [[ -n "${!var:-}" ]] || { echo "missing $var in secrets/rcs.env"; exit 1; }
  done
  for var in $(compgen -v | grep '^RCS_IDM_PASSWORD_'); do
    props+=("rcs.idm.password.$(echo "${var#RCS_IDM_PASSWORD_}" | tr '[:upper:]' '[:lower:]')=${!var}")
  done
fi
for kv in "${props[@]}"; do
  key="${kv%%=*}"
  grep -v "^${key}=" "$BOOT" > "$BOOT.tmp" || true
  printf '%s\n' "$kv" >> "$BOOT.tmp"
  mv "$BOOT.tmp" "$BOOT"
done

# conf last: dropping the provisioner triggers connector activation
CONF=runtime/openidm/conf
if [[ "$TOPOLOGY" == rcs* ]]; then
  cp "idm-config/topology/$TOPOLOGY/provisioner.openicf.connectorinfoprovider.json" "$CONF/"
  if $CLIENT_MODE; then
    # Per-server RCS logins and this topology's openicf access rules, merged
    # into IDM's own config (vendor files not tracked). Our logins (username
    # *-client, incl. the retired shared connector-server-client) and all
    # openicf rules are replaced on every deploy, so switching topology leaves
    # nothing stale behind.
    jq --slurpfile m "idm-config/topology/$TOPOLOGY/auth-modules.json" \
      '.serverAuthContext.authModules |= (map(select(.name != "STATIC_USER" or ((.properties.username // "") | test("-client$") | not))) + $m[0])' \
      "$CONF/authentication.json" > "$CONF/authentication.json.tmp"
    mv "$CONF/authentication.json.tmp" "$CONF/authentication.json"
    jq --slurpfile r "idm-config/topology/$TOPOLOGY/access-rules.json" \
      '.configs |= (map(select(.servlet != "openicf")) + $r[0])' \
      "$CONF/access.json" > "$CONF/access.json.tmp"
    mv "$CONF/access.json.tmp" "$CONF/access.json"
  fi
  RCS_SCRIPT_ROOT="$PWD/rcs/openicf/scripts/databricks"; RCS_HOST_REF=rcslocal
  [[ "$TOPOLOGY" == rcs-k8s ]] && { RCS_SCRIPT_ROOT=/opt/openicf/scripts/databricks; RCS_HOST_REF=databricks; }
  for f in idm-config/conf/*.json; do
    if [[ "$(basename "$f")" == provisioner.openicf-databricks.json ]]; then
      jq --arg root "$RCS_SCRIPT_ROOT" --arg host "$RCS_HOST_REF" \
        '.connectorRef.connectorHostRef = $host | .configurationProperties.scriptRoots = [$root]' \
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
