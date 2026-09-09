#!/usr/bin/env bash
# Deploy tracked connector config into the (gitignored) IDM runtime:
#   - conf/*.json           -> runtime/openidm/conf/           (hot-reloaded)
#   - script/*.groovy       -> runtime/openidm/script/databricks/
#   - databricks.pat + databricks.jdbc.url -> resolver/boot.properties
#     (values sourced from secrets/databricks.env; never tracked)
# Idempotent — rerun after any config/script/secret change.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a; source secrets/databricks.env; set +a
: "${DATABRICKS_PAT:?missing in secrets/databricks.env}"
: "${DATABRICKS_JDBC_URL:?missing in secrets/databricks.env}"

BOOT=runtime/openidm/resolver/boot.properties
[[ -f "$BOOT" ]] || { echo "no $BOOT — is IDM extracted?"; exit 1; }

mkdir -p runtime/openidm/script/databricks
cp idm-config/script/*.groovy runtime/openidm/script/databricks/

# boot.properties: replace-or-append each substitution property
for kv in "databricks.pat=${DATABRICKS_PAT}" "databricks.jdbc.url=${DATABRICKS_JDBC_URL}"; do
  key="${kv%%=*}"
  grep -v "^${key}=" "$BOOT" > "$BOOT.tmp" || true
  printf '%s\n' "$kv" >> "$BOOT.tmp"
  mv "$BOOT.tmp" "$BOOT"
done

# conf last: dropping the provisioner triggers connector activation
cp idm-config/conf/*.json runtime/openidm/conf/

echo "deployed: $(ls idm-config/conf/*.json | wc -l | tr -d ' ') conf file(s), $(ls idm-config/script/*.groovy | wc -l | tr -d ' ') script(s); boot.properties updated"
