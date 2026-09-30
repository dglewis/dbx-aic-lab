#!/usr/bin/env bash
# Deploy tracked RCS files into the (gitignored) RCS distribution:
#   - rcs/conf/ConnectorServer.properties -> rcs/openicf/conf/
#   - RCS_KEY (secrets/rcs.env)           -> hashed into the properties via /setKey
#   - idm-config/script/*.groovy          -> rcs/openicf/scripts/databricks/
#   - databricks-jdbc driver jar          -> rcs/openicf/lib/  (same classloader
#     as the connector's embedded tomcat-jdbc, per the RCS docs)
# Idempotent. Restart the RCS afterwards (rcs/run.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -d rcs/openicf/connectors ]] || { echo "no rcs/openicf — run rcs/fetch-rcs.sh first"; exit 1; }
set -a; source secrets/rcs.env; set +a
: "${RCS_KEY:?missing in secrets/rcs.env}"
[[ "$RCS_KEY" =~ ^[A-Za-z0-9]+$ ]] || { echo "RCS_KEY must be alphanumeric"; exit 1; }

DRIVER=runtime/openidm/lib/databricks-jdbc-2.7.3.jar
[[ -f "$DRIVER" ]] || { echo "no $DRIVER — fetch it per the README runbook"; exit 1; }

export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"

cp rcs/conf/ConnectorServer.properties rcs/openicf/conf/ConnectorServer.properties
rcs/openicf/bin/ConnectorServer.sh /setKey "$RCS_KEY" >/dev/null

mkdir -p rcs/openicf/scripts/databricks
cp idm-config/script/*.groovy rcs/openicf/scripts/databricks/
cp "$DRIVER" rcs/openicf/lib/

echo "deployed: properties + key, $(ls idm-config/script/*.groovy | wc -l | tr -d ' ') script(s), $(basename "$DRIVER")"
