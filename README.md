# db-conn — Databricks ⇄ PingAIC connector lab

A working prototype of a **bidirectional ICF connector between Databricks and
PingOne Advanced Identity Cloud**, built and validated on a local lab:
self-hosted PingIDM 8.1.1 stands in for AIC (AIC's sync engine *is* IDM, so
provisioner and mapping config ports to a tenant nearly unchanged), and a
Databricks Free Edition workspace is the real target — driver compatibility
was the whole question, so Databricks is never mocked.

> **Status: spike/prototype, not production.** Phase 1 (in-process connector)
> is complete and evidence-backed — CRUD, paging, filtered queries, and
> CDF-based liveSync including delete detection, authenticated as a
> service principal via OAuth M2M. It has not been hardened, load-tested, or
> security-reviewed. Copy patterns, not guarantees.

![Architecture](docs/architecture.svg)

## What's decided, and why

- **Connector: ScriptedSQL (Groovy)** over the config-only DatabaseTable
  connector — decided by authentication posture (production needs
  service-principal OAuth M2M with secrets kept out of plaintext config,
  which only the scripted connector reaches cleanly) plus single-provisioner
  topology and CDF delete detection. Full trade-off analysis with citations:
  [ADR-001](docs/adr-001-connector-selection.md).
- **Sync: Delta Change Data Feed** — the sync token is the Delta commit
  version, so liveSync sees inserts, updates, **and deletes**.
- **Auth: OAuth M2M as a service principal** — assembled at connector init
  by a customizer script from an IDM-encrypted config property; works on
  Databricks **Free Edition** (a commonly repeated claim that it doesn't was
  disproven empirically — see [spike results](docs/spike-results.md)).

The documentation trail, in reading order:
[ADR-001](docs/adr-001-connector-selection.md) (why this connector) →
[design](docs/design.md) (the as-built system) →
[plan](docs/plan.md) (phases and status) →
[spike results](docs/spike-results.md) (dated findings, including retracted
ones).

## What you need

- A **Ping Identity Backstage account** — `IDM-8.1.1.zip` and `DS-8.1.1.zip`
  are proprietary, **not included in this repo and not redistributable**
  (see [NOTICE](NOTICE.md)); download them into the repo root yourself.
- A **Databricks Free Edition** workspace (free signup) with a SQL warehouse.
- macOS/Linux with Homebrew-installable **JDK 21 and JDK 25** (split-JDK
  requirement is real — see prerequisites below) and **Node 18+** for the
  test suite.

## Quickstart

```bash
# 1. Vendor artifacts (Backstage) -> repo root: IDM-8.1.1.zip, DS-8.1.1.zip
# 2. Stand up DS + IDM: follow the Runbook section below (one-time setup)
# 3. Configure credentials:
cp secrets/databricks.env.example secrets/databricks.env   # then fill it in
# 4. Create the lab tables (CDF on, seed rows):
databricks/apply-sql.sh databricks/sql/001_lab_tables.sql
# 5. Deploy connector config + scripts into the runtime:
idm-config/deploy.sh
# 6. Prove it works (16 checks; writes test/runs/ + JUnit XML):
cd test && npm install && npm test
```

The suite needs the live lab — it is a manual gate, not a CI job.

## Layout

| Path | Tracked | Purpose |
|---|---|---|
| `runtime/openidm/` | no (gitignored) | Extracted IDM 8.1.1 — rebuild via `unzip IDM-8.1.1.zip -d runtime/` |
| `runtime/opendj/` | no (gitignored) | Extracted DS 8.1.1 (IDM's repository) — binaries AND live instance data; `rm -rf runtime/` is the lab reset |
| `secrets/` | no (gitignored) | Sensitive material: DS deployment ID, CA cert, Databricks PAT/env |
| `idm-config/conf/` | yes | Provisioner + mapping JSON (`provisioner.openicf-*.json`, `sync.json`) — copied into `runtime/openidm/conf/` |
| `idm-config/script/` | yes | ScriptedSQL Groovy scripts (one per ICF operation + customizer) |
| `databricks/` | yes | Lab tooling: `smoke-test.sh` (JDBC connectivity), `apply-sql.sh` + `JdbcRunner.java` (run SQL over the driver), `sql/` (DDL, CDF setup, seed data) |
| `test/` | yes | Node/Vitest acceptance suite (`cd test && npm install && npm test`) — IDM REST assertions + Databricks-native out-of-band checks over the SQL Statement Execution REST API; profile-driven (`PROFILE=lab\|tenant`); writes `test/runs/acceptance-node-*.log` + JUnit XML |
| `rcs/` | yes | Phase-2 Java RCS config |
| `docs/` | yes | ADR, design, plan, spike results — the narrative record |
| `test/runs/` | no (gitignored) | Local HTTP request/response logs, one per acceptance/soak run |
| `secrets/databricks.env.example` | yes | Credential template — the only tracked file under `secrets/` |

## Phases

1. **In-process spike** — ScriptedSQL (Groovy) connector jar is already in
   `runtime/openidm/connectors/`; Databricks JDBC jar in `openidm/lib/`;
   author the Groovy scripts, configure one provisioner against Databricks
   Free Edition, run test/recon/CRUD/liveSync (CDF sync token).
2. **RCS topology rehearsal** — move connector + driver jars to a local Java
   RCS (server mode), point IDM at it.
3. **Real AIC tenant** — flip RCS to client mode with tenant OAuth creds.
   Databricks auth is already service-principal OAuth M2M (migrated in the
   lab — Free Edition supports SP OAuth after all; see docs/design.md
   checklist): recreate SP + grants in the tenant workspace, secrets to ESVs.

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
