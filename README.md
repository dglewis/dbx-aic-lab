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
| `runtime/openidm/` | no (gitignored) | Extracted IDM 8.1.1 — rebuild via `unzip ~/Downloads/IDM-8.1.1.zip -d runtime/` |
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

## Runbook

```bash
# start IDM (needs JDK 17 — default on this machine)
cd runtime/openidm && ./startup.sh
# admin UI: https://localhost:8443/admin  (openidm-admin / openidm-admin)

# fetch the Databricks JDBC driver (OSS, Apache 2.0) into the connectors dir
mvn dependency:copy -Dartifact=com.databricks:databricks-jdbc:LATEST \
  -DoutputDirectory=runtime/openidm/connectors/
```

Secrets (Databricks PAT, warehouse HTTP path) live in untracked `*.env` /
`secrets/` — see `.gitignore`. Sync token format, if timestamp-based:
`yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` (UTC, full microseconds, column type
`TIMESTAMP` not `TIMESTAMP_NTZ`).
