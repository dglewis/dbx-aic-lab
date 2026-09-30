#!/usr/bin/env bash
# Run the Java RCS in the foreground on JDK 21 (Ctrl-C to stop), in whichever
# mode rcs/deploy.sh last configured. In client mode the IDM credentials from
# secrets/rcs.env are passed as -D options (they override the properties file).
# Logs: rcs/openicf/logs/ (ConnectorServer.log; connector/Groovy output in Connector.log).
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ../secrets/rcs.env; set +a
cd openicf
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"

OPENICF_OPTS="-Xmx1g -Xms1g"
if grep -q '^connectorserver.url=' conf/ConnectorServer.properties; then
  : "${RCS_IDM_PRINCIPAL:?missing in secrets/rcs.env}" "${RCS_IDM_PASSWORD:?missing in secrets/rcs.env}"
  for v in "$RCS_IDM_PRINCIPAL" "$RCS_IDM_PASSWORD"; do
    [[ "$v" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RCS_IDM_* must be letters/digits/._-"; exit 1; }
  done
  # The vendor start script echoes OPENICF_OPTS, so the credentials go in a
  # JDK @argfile (mode 600, gitignored dir) and only its path is echoed.
  ARGS="$PWD/tmp/idm-credentials.args"
  mkdir -p tmp; ( umask 077; printf '%s\n' \
    "-Dconnectorserver.principal=$RCS_IDM_PRINCIPAL" \
    "-Dconnectorserver.password=$RCS_IDM_PASSWORD" > "$ARGS" )
  OPENICF_OPTS="$OPENICF_OPTS @$ARGS"
fi
export OPENICF_OPTS
exec bin/ConnectorServer.sh /run
