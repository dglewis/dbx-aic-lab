# db-conn — Databricks ⇄ PingAIC connector experiment

Workspace for prototyping a bidirectional ICF connector between Databricks and
PingOne Advanced Identity Cloud, mocked locally with self-hosted PingIDM 8.1.1
(AIC's sync engine is IDM, so mappings/provisioner configs transfer to the
tenant nearly unchanged).

## Design under test

- **Inbound** (Databricks → IDM): full CRUD on a business-data table
  (ID, ID, datetime), one attribute set read-only. Recon + timestamp liveSync.
- **Outbound** (IDM → Databricks): disjoint dataset, separate mapping to a
  second table.
- **Spike question:** does the bundled DatabaseTable connector survive the
  Databricks JDBC driver (dialect, auto-commit-only transactions, metadata
  calls)? If yes, keep it (config-only). If it fights, fall back to
  ScriptedSQL — both connector jars ship with IDM 8.1.1.

## Layout

| Path | Tracked | Purpose |
|---|---|---|
| `runtime/openidm/` | no (gitignored) | Extracted IDM 8.1.1 — rebuild via `unzip IDM-8.1.1.zip -d runtime/` |
| `runtime/opendj/` | no (gitignored) | Extracted DS 8.1.1 (IDM's repository) — binaries AND live instance data; `rm -rf runtime/` is the lab reset |
| `secrets/` | no (gitignored) | Sensitive material: DS deployment ID, CA cert, Databricks PAT/env |
| `idm-config/conf/` | yes | Provisioner + mapping JSON (`provisioner.openicf-*.json`, `sync.json`) — copied into `runtime/openidm/conf/` |
| `idm-config/script/` | yes | Groovy scripts if the ScriptedSQL fallback is needed |
| `databricks/sql/` | yes | Table DDL, CDF setup, seed data |
| `rcs/` | yes | Phase-2 Java RCS config |
| `docs/` | yes | Notes, spike results |

## Phases

1. **In-process spike** — DatabaseTable connector jar is already in
   `runtime/openidm/connectors/`; add the Databricks JDBC jar there, configure
   a provisioner against Databricks Free Edition, run test/recon/CRUD/liveSync.
2. **RCS topology rehearsal** — move connector + driver jars to a local Java
   RCS (server mode), point IDM at it.
3. **Real AIC tenant** — flip RCS to client mode with tenant OAuth creds;
   swap Databricks PAT for an OAuth M2M service principal.

## Prerequisites (per the 8.1 install guide)

- **Two JDKs — IDM 8.1 requires Java 21; DS 8.1 requires Java 25** (verified:
  DS 8.1.1 classes are compiled for class-file 69). Both installed sudo-free via
  `brew install openjdk@21 openjdk@25`; IDM gets `JAVA_HOME`=21, DS gets
  `DS_JAVA_HOME`=25.
- Repository: **IDM 8.x has no embedded repo — a running PingDS instance is
  required before first boot.** The shipped `conf/repo.ds.json` has
  `"embedded": false` and expects DS at localhost:31389 (startTLS,
  `uid=admin` / `str0ngAdm1nPa55word`). DS-8.1.1.zip lives at the repo root;
  extract to `runtime/opendj/` and set up with the `idm-repo` profile (see
  runbook). DS 8.1 requires Java 25 (see Java bullet above).
  **Base DN (verified):** `repo.ds.json` expects `dc=openidm,dc=forgerock,dc=com`,
  but the `idm-repo` profile defaults to domain `example.com` — setup MUST pass
  `--set idm-repo/domain:forgerock.com`.
- The **legacy admin UI is not bundled in 8.1** (deprecated; separate Backstage
  download). Lab admin happens over REST — connector/mapping config is JSON in
  `conf/` anyway, which suits this repo's tracked-config approach.
- macOS is not a supported OS for production IDM — fine for this lab only.
- Eval sizing: ≥1 GB RAM, 10 GB disk (DS repo wants 5% of filesystem + 1 GB free).

## Runbook

```bash
# Split JDKs via sudo-free Homebrew formulas (temurin casks need interactive
# sudo). One-time: brew install openjdk@21 openjdk@25
# NB: /usr/libexec/java_home can't see keg-only brew JDKs — set paths directly.
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"      # IDM
export DS_JAVA_HOME="$(brew --prefix openjdk@25)/libexec/openjdk.jdk/Contents/Home"   # DS tools + server
"$JAVA_HOME/bin/java" -version && "$DS_JAVA_HOME/bin/java" -version || exit 1

# --- one-time DS repo setup (before first IDM start) ---
# Source of truth: PingIDM 8.1 install-guide/external-ds.html +
# PingDS 8.1 install-guide/profile-idm-repo.html.
# The guide's "replace conf/repo.ds.json with db/ds/conf/repo.ds-external.json"
# step is a no-op in IDM 8.1.1 — shipped files are identical (verified by diff).
unzip DS-8.1.1.zip -d runtime/          # -> runtime/opendj
runtime/opendj/bin/dskeymgr create-deployment-id \
  --deploymentIdPassword password > secrets/ds-deployment-id
export DEPLOYMENT_ID=$(cat secrets/ds-deployment-id)
runtime/opendj/setup \
  --deploymentId "$DEPLOYMENT_ID" --deploymentIdPassword password \
  --rootUserDN uid=admin --rootUserPassword str0ngAdm1nPa55word \
  --hostname localhost --adminConnectorPort 34444 --ldapPort 31389 \
  --enableStartTls --profile idm-repo \
  --set idm-repo/domain:forgerock.com \
  --acceptLicense
# optional, per DS guide (IDM manages passwords, not DS):
runtime/opendj/bin/dsconfig set-password-policy-prop \
  --policy-name "Default Password Policy" --reset password-validator --offline --no-prompt
runtime/opendj/bin/dsconfig set-password-policy-prop \
  --policy-name "Root Password Policy" --reset password-validator --offline --no-prompt
# trust: import the deployment-ID CA into IDM's truststore
runtime/opendj/bin/dskeymgr export-ca-cert --deploymentId "$DEPLOYMENT_ID" \
  --deploymentIdPassword password --outputFile secrets/ds-ca-cert.pem
keytool -importcert -noprompt -alias ds-ca-cert -file secrets/ds-ca-cert.pem \
  -keystore runtime/openidm/security/truststore \
  -storepass:file runtime/openidm/security/storepass
runtime/opendj/bin/start-ds

# --- IDM ---
cd runtime/openidm && ./startup.sh
# verify: DS side  -> grep 31389 runtime/opendj/logs/ldap-access.audit.json | tail -1
#         IDM side -> curl -k -u openidm-admin:openidm-admin https://localhost:8443/openidm/info/ping

# Databricks JDBC driver (OSS, Apache 2.0) — goes in openidm/lib/ (third-party
# JDBC drivers, per the ScriptedSQL sample docs), NOT connectors/ (ICF bundles
# only — IDM logs "Failed to add connector" if the driver lands there):
mvn dependency:copy -Dartifact=com.databricks:databricks-jdbc:2.7.3 \
  -DoutputDirectory=runtime/openidm/lib/
```

Secrets (Databricks PAT, warehouse HTTP path) live in untracked `*.env` /
`secrets/` — see `.gitignore`. Sync token format, if timestamp-based:
`yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` (UTC, full microseconds, column type
`TIMESTAMP` not `TIMESTAMP_NTZ`).
