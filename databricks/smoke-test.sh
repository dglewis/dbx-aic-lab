#!/usr/bin/env bash
# Phase-0 connectivity smoke test: standalone JDBC SELECT through the same
# driver jar IDM will use. Proves network + auth (OAuth M2M, or the optional
# PAT — ADR-002) + driver before any connector configuration exists.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source secrets/databricks.env; set +a
JAVA="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home/bin/java"

exec "$JAVA" -cp runtime/openidm/lib/databricks-jdbc-2.7.3.jar \
  databricks/JdbcRunner.java \
  "SELECT 1 AS smoke, current_catalog() AS catalog, current_schema() AS schema, current_user() AS who"
