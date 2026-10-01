# Databricks requirements for the ICF connector

What the Databricks administrator needs to provide for the ScriptedSQL
connector (Databricks JDBC driver, OAuth M2M). Background and rationale:
[design.md → "Sync / change detection"](design.md#sync--change-detection)
and [ADR-002](adr-002-databricks-authentication.md).

## Tables

- **Type:** a Delta table in Unity Catalog, managed or external. Views,
  federated (foreign) tables and non-Delta files have no change feed; views,
  materialized views and streaming tables are not writable.
- **Not a materialized view or streaming table** (Lakeflow/DLT outputs),
  even for read-only sync, unless tested first: a materialized view's change
  feed is Beta and a full refresh reports every row as changed; a streaming
  table has a change feed only when fed by an AUTO CDC flow.
- **Change Data Feed on:** `delta.enableChangeDataFeed = true`, enabled
  before the first full load. Tell us the version at which it was enabled.
  Turning it on is one `ALTER TABLE … SET TBLPROPERTIES` by someone with
  `MODIFY` on the table (usually its owner — not us). Nothing runs
  separately: Delta writes the change records in the same transaction as
  each write; we read them with queries on your SQL warehouse.
  Also `delta.enableRowTracking = true` (required by Databricks' newer
  "automatic" CDF; already on by default for new managed tables).
- **Key:** one non-null, unique column that never changes after insert.
- **Timestamps:** `TIMESTAMP` (UTC), not `TIMESTAMP_NTZ`.
- **No row filters or column masks** on these tables.
- **Outbound:** a table the connector may write to — ideally a landing table
  you merge from.

Verify: `SHOW TBLPROPERTIES <catalog>.<schema>.<table>`.

## Table shape

Give the connector **one row per object** holding its current state,
updated in place. If you also keep history, keep it in a separate table
the connector doesn't read. In slowly changing dimension (SCD) terms,
from best fit to worst:

| Rank | SCD type | Shape | Fit for the connector |
|---|---|---|---|
| 1 | Type 1 | One row per object; changed rows updated in place | Best: one change-feed event per change, deletes detected, and a full reconciliation reads one row per object |
| 1 | Type 4 | A Type 1 current-state table, plus a separate history table | Best: the connector reads only the current-state table |
| 3 | Type 3 | One row per object, plus "previous value" columns | Good: behaves like Type 1 |
| 4 | Type 2 | One row per version; the object's key repeats | Poor: the connector must reduce it to the latest row per key, and a full reconciliation scans all history, so it slows as history grows |
| 5 | Type 6 | Type 2, plus current-value columns on every version | Worst: as Type 2, and each change rewrites every version of the object |

Whatever the type, load it with row-level writes
([Keeping the sync position valid](#keeping-the-sync-position-valid)):
a full overwrite reports every row as changed on every run.

## Keeping the sync position valid

The connector's sync token is the table's Delta commit version.

- **Retention:** state `delta.logRetentionDuration`,
  `delta.deletedFileRetentionDuration` and your `VACUUM` schedule. The
  shorter of these is our recovery window: an outage longer than it needs a
  full reload.
- **Tell us in advance** before: dropping/recreating the table
  (`CREATE OR REPLACE`), `RESTORE`, `INSERT OVERWRITE`, turning CDF off, or
  renaming/dropping/retyping columns. Each resets or blocks the change feed.
  Adding columns is fine.
- Prefer row-level writes (`INSERT`, `UPDATE`, `DELETE`, `MERGE`). Hard
  deletes are fine; if you soft-delete, name the flag column.

## Access

- A **service principal** with an OAuth secret (no personal access tokens).
  Send us the client ID; deliver the secret through a secure channel.
- Grants: `USE CATALOG`, `USE SCHEMA`; `SELECT` on tables we read (that
  covers reading the change feed with `table_changes()`);
  `SELECT, MODIFY` on tables we write; `CAN USE` on the SQL warehouse.

## Compute and connectivity

- A **SQL warehouse** (serverless preferred). No particular runtime (DBR
  or DBSQL) version or JDBC driver is needed for the change feed. Tell us its auto-stop setting —
  our poll interval is chosen with it in mind.
- Workspace host, warehouse HTTP path, OAuth token endpoint
  (`https://<workspace>/oidc/v1/token`).
- If IP access lists or private connectivity are in use, allow the
  connector host's egress.
