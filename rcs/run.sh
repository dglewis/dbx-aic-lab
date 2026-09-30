#!/usr/bin/env bash
# Run the Java RCS in the foreground on JDK 21 (Ctrl-C to stop), in whichever
# mode rcs/deploy.sh last configured. In client mode the RCS logs in as
# <server>-client with RCS_IDM_PASSWORD_<SERVER> from secrets/rcs.env (one
# login per connector server), passed as -D options.
# Logs: rcs/openicf/logs/ (ConnectorServer.log; connector/Groovy output in Connector.log).
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ../secrets/rcs.env; set +a
cd openicf
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

OPENICF_OPTS="-Xmx1g -Xms1g"
if grep -q '^connectorserver.url=' conf/ConnectorServer.properties; then
  SERVER=$(sed -n 's/^connectorserver.connectorServerName=//p' conf/ConnectorServer.properties)
  var="RCS_IDM_PASSWORD_$(echo "$SERVER" | tr '[:lower:]' '[:upper:]')"
  PASSWORD="${!var:-}"
  [[ "$PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "$var missing or not letters/digits/._- in secrets/rcs.env"; exit 1; }
  # The vendor start script echoes OPENICF_OPTS, so the credentials go in a
  # JDK @argfile (mode 600, gitignored dir) and only its path is echoed.
  ARGS="$PWD/tmp/idm-credentials.args"
  mkdir -p tmp; ( umask 077; printf '%s\n' \
    "-Dconnectorserver.principal=${SERVER}-client" \
    "-Dconnectorserver.password=$PASSWORD" > "$ARGS" )
  OPENICF_OPTS="$OPENICF_OPTS @$ARGS"
fi
export OPENICF_OPTS
exec bin/ConnectorServer.sh /run
