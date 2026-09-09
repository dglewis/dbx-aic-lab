#!/usr/bin/env bash
# Apply a SQL file (or run ad-hoc statements) against the lab warehouse via
# the same JDBC driver IDM uses. Usage:
#   databricks/apply-sql.sh databricks/sql/001_lab_tables.sql
#   databricks/apply-sql.sh "SELECT * FROM workspace.idm_lab.business_records"
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source secrets/databricks.env; set +a
JAVA="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home/bin/java"

args=()
for a in "$@"; do
  if [[ -f "$a" ]]; then args+=("@$a"); else args+=("$a"); fi
done

exec "$JAVA" -cp runtime/openidm/lib/databricks-jdbc-2.7.3.jar \
  databricks/JdbcRunner.java "${args[@]}"
