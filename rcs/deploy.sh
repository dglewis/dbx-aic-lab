#!/usr/bin/env bash
# Deploy tracked RCS files into the (gitignored) RCS distribution.
#
# Usage: rcs/deploy.sh [client|server]      (default: client)
#   client — the target (AIC supports only client mode): the RCS connects out
#            to IDM. Imports IDM's certificate into the RCS truststore.
#   server — stepping stone only: IDM connects in on 8759; sets the shared
#            key (RCS_KEY) via /setKey.
# Both: rcs/conf/<mode>/ConnectorServer.properties -> rcs/openicf/conf/,
#       idm-config/script/*.groovy -> rcs/openicf/scripts/databricks/,
#       databricks-jdbc driver jar -> rcs/openicf/lib/ (same classloader as the
#       connector's embedded tomcat-jdbc, per the RCS docs).
# Idempotent. Restart the RCS afterwards (rcs/run.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-client}"
case "$MODE" in client|server) ;; *) echo "usage: $0 [client|server]"; exit 2 ;; esac

[[ -d rcs/openicf/connectors ]] || { echo "no rcs/openicf — run rcs/fetch-rcs.sh first"; exit 1; }
set -a; source secrets/rcs.env; set +a

DRIVER=runtime/openidm/lib/databricks-jdbc-3.4.3.jar
[[ -f "$DRIVER" ]] || { echo "no $DRIVER — fetch it per the README runbook"; exit 1; }

export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"

cp "rcs/conf/$MODE/ConnectorServer.properties" rcs/openicf/conf/ConnectorServer.properties

if [[ "$MODE" == server ]]; then
  : "${RCS_KEY:?missing in secrets/rcs.env}"
  [[ "$RCS_KEY" =~ ^[A-Za-z0-9]+$ ]] || { echo "RCS_KEY must be alphanumeric"; exit 1; }
  rcs/openicf/bin/ConnectorServer.sh /setKey "$RCS_KEY" >/dev/null
else
  # Trust IDM's (self-signed) server certificate, keeping the public CAs the
  # Databricks driver needs — the RCS uses this one store JVM-wide.
  IDM_SEC=runtime/openidm/security
  "$JAVA_HOME/bin/keytool" -exportcert -rfc -alias openidm-localhost \
    -keystore "$IDM_SEC/keystore.jceks" -storetype JCEKS \
    -storepass:file "$IDM_SEC/storepass" > rcs/openicf/security/idm.pem
  "$JAVA_HOME/bin/keytool" -delete -alias idm-local -keystore rcs/openicf/security/truststore \
    -storepass changeit >/dev/null 2>&1 || true
  "$JAVA_HOME/bin/keytool" -importcert -noprompt -alias idm-local -file rcs/openicf/security/idm.pem \
    -keystore rcs/openicf/security/truststore -storepass changeit >/dev/null
fi

mkdir -p rcs/openicf/scripts/databricks
cp idm-config/script/*.groovy rcs/openicf/scripts/databricks/
rm -f rcs/openicf/lib/databricks-jdbc-*.jar   # never two drivers on the classpath
cp "$DRIVER" rcs/openicf/lib/

echo "deployed ($MODE): properties, $(ls idm-config/script/*.groovy | wc -l | tr -d ' ') script(s), $(basename "$DRIVER")"
