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

- **Connector (lab and production): service-principal OAuth M2M**
  (`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret`, access tokens valid one
  hour) — migrated in the lab 2026-09-09 as SP `idm-connector-lab`. Reaching
  this cleanly decided ADR-001 for ScriptedSQL. Pool `maxAge` is 50 min so
  no pooled connection outlives its token (driver M2M auto-refresh is
  undocumented).
- **PAT (admin tooling only):** the connector no longer holds a PAT —
  `deploy.sh` removes `databricks.pat` from `boot.properties`. The BI-Tools-
  scoped PAT in `secrets/` remains for admin-side lab tooling only
  (`apply-sql.sh`, `smoke-test.sh`, grants, acceptance out-of-band checks).

### Credential path (ScriptedSQL, as built)

The provisioner's `customSensitiveConfiguration` — a GuardedString property,
**encrypted by IDM at rest** — carries
`oauth2 { clientId = '&{databricks.sp.client.id}'; secret = '&{databricks.sp.client.secret}' }`,
substituted from `resolver/boot.properties` (lab; ESVs in AIC), synced from
`secrets/` by `idm-config/deploy.sh`. At connector init the framework decrypts
it into `configuration.propertyBag`, and `CustomizerScript.groovy` strips any
auth params from the base `&{databricks.jdbc.url}` and appends the M2M set —
so the secret exists only in encrypted config and in memory, never in a
plaintext property. `username`/`password` are unused placeholders (the driver
ignores UID/PWD under `AuthMech=11`; verified). Rotation = new SP secret →
update the secret source → recycle the connector; tracked config unchanged.

**Verified toolkit fact (1.5.20.33):** the scripted-sql customizer is a plain
script body with `configuration` in the binding; the scripted-REST
`customize { init { … } }` DSL breaks script loading here. The ScriptedSQL
doc page omits the customizer/custom-config properties, but
`ScriptedSQLConfiguration` inherits them from `ScriptedConfiguration`
(verified via javap and live probe).

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
   `boot.properties` substitution into the encrypted
   `customSensitiveConfiguration`; AIC → ESVs referenced by the RCS.
   ✔ lab
5. **Switch to the customizer:** `CustomizerScript.groovy` assembles
   `AuthMech=11;Auth_Flow=1;OAuth2ClientId/OAuth2Secret` at init (replacing
   `AuthMech=3;UID=token;PWD=<pat>`). ✔ lab — acceptance 15/15 as the SP,
   confirmed by Databricks query history
6. **Validate token refresh over a held-open pool:** pool `maxAge=3000000`
   (50 min) recycles connections inside the 1-hour token window; soak test
   past the boundary (`databricks/soak-test.sh`, evidence under
   `docs/evidence/`). Note: after an IDM restart against a cold serverless
   warehouse, the first M2M connect (token exchange + warehouse wake) can
   make early operations fail transiently until the pool establishes —
   self-heals; consider warm-up/retry in production.
7. **Retire the PAT:** ✔ connector side — `deploy.sh` purges
   `databricks.pat` from `boot.properties`, so IDM holds no PAT. Workspace
   revocation is optional while admin lab tooling (`apply-sql.sh` etc.)
   still authenticates with it; revoke when that tooling moves to the SP or
   at spike end.
8. **Rotation thereafter:** rotate the OAuth secret at the source (new
   secret → update ESV/env → recycle connector); connector config untouched.

## Topology phases

1. Connector in-process in local IDM (current).
2. Same connector on local Java RCS, server mode; IDM points at RCS.
3. AIC tenant: RCS flips to client mode (websocket out to tenant); PAT → M2M;
   provisioner/mapping JSON ports with connectorRef changes only.
