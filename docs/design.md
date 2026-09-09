# Design — Databricks ⇄ PingAIC bidirectional connector

Status: current as of phase 1 (local lab). Decisions cite [ADR-001](adr-001-connector-selection.md).

## Components

| Component | Role | Phase-1 realization |
|---|---|---|
| Databricks | System of record (inbound) / target (outbound) | Free Edition, serverless SQL warehouse, Unity Catalog, Delta tables |
| ICF connector | CRUD + sync over JDBC | **ScriptedSQL (Groovy)** — decided per ADR-001 (auth posture + topology); bundled in IDM 8.1.1 |
| JDBC driver | Wire protocol | OSS `databricks-jdbc` 2.7.3, class `com.databricks.client.jdbc.Driver` (verified from jar), in `openidm/lib/` |
| Sync engine | Recon, liveSync, mappings | Local PingIDM 8.1.1 (DS-backed) standing in for AIC — same engine, configs port to tenant |
| RCS | Connector host in production topology | Phase 2 (local, server mode) → phase 3 (AIC tenant, client mode) |

## Data model (lab; real names swap in later)

Both tables: an ID, a second ID, a datetime stamp. Delta, Unity Catalog.

- **Inbound source:** `<catalog>.idm_lab.business_records`
  `record_id STRING` (key), `ref_id STRING`, `last_modified TIMESTAMP`
  Change Data Feed enabled (serves the ScriptedSQL sync path if needed).
- **Outbound target:** `<catalog>.idm_lab.outbound_records`
  same shape, disjoint data.

Column type is `TIMESTAMP` (not `TIMESTAMP_NTZ`); timestamp interchange format
is `yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` — UTC, full microseconds (Databricks
TIMESTAMP precision), fixed width so lexicographic order = chronological.

## IDM object model and mappings

Bidirectional = two unidirectional mappings over disjoint datasets (no loop risk):

| | Inbound | Outbound |
|---|---|---|
| System object | `system/databricks/businessRecord` | `system/databricks/outboundRecord` |
| Managed object | `managed/businessRecord` (target) | `managed/outboundRecord` (source) |
| Mapping | recon + liveSync (CDF sync token) | implicit sync on managed-object change + recon |

**Provisioner naming convention:** a provisioner is named for the *system* it
connects to — never for a flow direction, which belongs to mappings. With
ScriptedSQL decided (ADR-001), a single `provisioner.openicf-databricks.json`
serves both directions: one connector instance, two object classes named for
their datasets.

## Read-only attribute set (inbound)

Attribute list TBD (business decision). Enforcement is two-layer:
- Connector level: declared `NOT_UPDATEABLE`/`NOT_CREATABLE` in
  `SchemaScript.groovy` (flags verified in the shipped framework jar).
- Mapping level: attributes absorbed source→managed only; never mapped
  managed→source.

## Sync / change detection

Sync token = CDF `_commit_version` (Long) via `table_changes()` in
`SyncScript.groovy`: detects creates, updates, **and deletes**; no
timestamp-precision pitfalls. The `last_modified` column remains as data (and
as a fallback token strategy) but is not the sync mechanism.

## Authentication

- **Lab:** PAT (`AuthMech=3;UID=token` semantics), scoped to the **BI Tools**
  preset (SQL-warehouse connections — the JDBC connector's exact class; manual
  equivalent is the `sql` API scope). Value supplied via IDM property
  substitution `&{databricks.pat}` — tracked configs never contain secrets;
  the value lives in `resolver/boot.properties` (gitignored runtime) sourced
  from `secrets/`. Note: Databricks has no ICF-specific integration — its
  integrations catalog treats JDBC clients as BI-tool-class connections, which
  is how this connector presents.
- **Why PAT (for now):** historical only — the original "Free Edition can't
  do SP OAuth" rationale was disproven 2026-09-09 (ADR-001, retracted
  lab-auth finding): SP `idm-connector-lab` + workspace-generated OAuth
  secret + M2M token exchange + JDBC `AuthMech=11` all verified working on
  this workspace. The PAT remains the connector's current auth until the
  migration below is executed, which the lab can now do without waiting for
  a paid workspace.
- **Production:** service-principal OAuth M2M
  (`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret`), access tokens valid one
  hour. Reaching this cleanly decided ADR-001 for ScriptedSQL.

### Credential path (ScriptedSQL)

Lab (PAT): the connector's pooled connection uses the provisioner's
`username`/`password` properties (`token` / `&{databricks.pat}`) with the
URL in `&{databricks.jdbc.url}` — values substituted from
`resolver/boot.properties`, synced from `secrets/` by `idm-config/deploy.sh`;
IDM encrypts the password property on config load. M2M: credential
acquisition moves into `CustomizerScript.groovy`, which reads the client
ID/secret from env/ESV at runtime and assembles the JDBC properties in code.
Tracked config never holds a secret in either phase, so the swap changes the
customizer + secret source only — no provisioner or mapping changes.

### Migration: PAT → OAuth M2M (service principal)

Works on Free Edition (verified 2026-09-09); steps 1–3 are **done** in the
lab for SP `idm-connector-lab` (client ID in `secrets/databricks.env`).

1. **Create the service principal** (workspace Settings → Identity and
   access → Service principals; or the workspace SCIM API). ✔ lab
2. **Generate an OAuth secret** for it (SP → Secrets → Generate secret) —
   record client ID + secret once. ✔ lab
3. **Least-privilege grants:** warehouse `CAN USE`; Unity Catalog `USE
   CATALOG`/`USE SCHEMA` plus `SELECT, MODIFY` on the two lab tables only.
   ✔ lab (verified: `SELECT current_user()` over JDBC returns the SP)
4. **Store the secret out of config:** lab → `secrets/databricks.env` +
   `boot.properties` substitution; AIC → ESVs referenced by the RCS.
5. **Switch the customizer:** connection properties become
   `AuthMech=11;Auth_Flow=1` with `OAuth2ClientId`/`OAuth2Secret` injected at
   runtime (replacing `AuthMech=3;UID=token;PWD=<pat>`).
6. **Validate token refresh over a held-open pool:** M2M auto-refresh is
   *not* explicitly documented for the driver (ADR-001 note). Soak-test a
   connector instance past the 1-hour token lifetime; if connections sour,
   have the customizer/pool recycle connections inside the token window.
7. **Retire the PAT:** revoke it in the workspace and delete
   `DATABRICKS_PAT` from `secrets/databricks.env`.
8. **Rotation thereafter:** rotate the OAuth secret at the source (new
   secret → update ESV/env → recycle connector); connector config untouched.

## Topology phases

1. Connector in-process in local IDM (current).
2. Same connector on local Java RCS, server mode; IDM points at RCS.
3. AIC tenant: RCS flips to client mode (websocket out to tenant); PAT → M2M;
   provisioner/mapping JSON ports with connectorRef changes only.
