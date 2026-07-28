# Design — Databricks ⇄ PingAIC bidirectional connector

Status: current as of phase 1 (local lab). Decisions cite [ADR-001](adr-001-connector-selection.md).

## Components

| Component | Role | Phase-1 realization |
|---|---|---|
| Databricks | System of record (inbound) / target (outbound) | Free Edition, serverless SQL warehouse, Unity Catalog, Delta tables |
| ICF connector | CRUD + sync over JDBC | DatabaseTable connector (spike); ScriptedSQL fallback — both bundled in IDM 8.1.1 |
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
| System object | `system/databricksInbound/account` | `system/databricksOutbound/account` |
| Managed object | `managed/businessRecord` (target) | `managed/outboundRecord` (source) |
| Mapping | recon + liveSync (`changeLogColumn` = `last_modified`) | implicit sync on managed-object change + recon |

**Provisioner naming convention:** a provisioner is named for the *system* it
connects to — never for a flow direction, which belongs to mappings. Preferred
shape: a single `provisioner.openicf-databricks.json` serving both directions.
ScriptedSQL supports this directly (one connector, two object classes).
DatabaseTable's one-table-per-instance limit forces two instances; if that path
wins the spike, instances are suffixed by *dataset*, not direction:
`provisioner.openicf-databricks-<table>.json`. This asymmetry is a
connector-selection input (ADR-001).

## Read-only attribute set (inbound)

Attribute list TBD (business decision). Enforcement:
- DatabaseTable path: attributes absorbed source→managed only; never mapped
  managed→source. Mapping-level enforcement only (connector has no schema flags).
- ScriptedSQL path: additionally declared `NOT_UPDATEABLE`/`NOT_CREATABLE` in
  `SchemaScript.groovy` (connector-level enforcement; flags verified in the
  shipped framework jar).

## Sync / change detection

- **DatabaseTable:** liveSync via `changeLogColumn: last_modified`. Documented
  limitation: create/update only — deletes require scheduled full recon.
- **ScriptedSQL fallback:** sync token = CDF `_commit_version` (Long) via
  `table_changes()`; detects deletes; no timestamp-precision pitfalls.

## Authentication

- **Lab:** PAT (`AuthMech=3;UID=token` semantics), value supplied via IDM
  property substitution `&{databricks.pat}` — tracked configs never contain
  secrets; the value lives in `resolver/boot.properties` (gitignored runtime)
  sourced from `secrets/`.
- **Production:** service-principal OAuth M2M
  (`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret`). Reaching this cleanly is a
  connector-selection criterion — see ADR-001 authentication posture.

## Topology phases

1. Connector in-process in local IDM (current).
2. Same connector on local Java RCS, server mode; IDM points at RCS.
3. AIC tenant: RCS flips to client mode (websocket out to tenant); PAT → M2M;
   provisioner/mapping JSON ports with connectorRef changes only.
