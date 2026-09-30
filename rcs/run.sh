#!/usr/bin/env bash
# Run the Java RCS in the foreground on JDK 21 (Ctrl-C to stop).
# Logs: rcs/openicf/logs/ (ConnectorServer.log; connector/Groovy output in Connector.log).
set -euo pipefail
cd "$(dirname "$0")/openicf"
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
exec bin/ConnectorServer.sh /run
