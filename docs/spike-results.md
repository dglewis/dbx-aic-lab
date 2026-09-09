# Spike results — ScriptedSQL vs Databricks Free Edition

Running log of Phase-1 acceptance evidence (docs/plan.md). ADR-001 already
selected ScriptedSQL; these results validate the choice or reopen it.

## 2026-09-09 — infrastructure built and wired; blocked on fresh PAT

### Verified working

- **JDBC URL format (driver 2.7.3):** the workspace-generated URL with a
  `/default` path segment (`jdbc:databricks://host:443/default;…`) fails to
  parse — driver error 500177 "Error getting http path from connection
  string". The documented format has properties directly after the port:
  `jdbc:databricks://<host>:443;transportMode=http;ssl=1;AuthMech=3;httpPath=<path>`.
  `secrets/databricks.env` corrected accordingly. With the corrected URL the
  driver resolves, negotiates TLS, and reaches the warehouse endpoint.
- **Network + TLS + warehouse reachability:** standalone smoke test
  (`databricks/smoke-test.sh`) reaches the workspace; server responds
  (with an auth error — see blocker).
- **Connector loads in IDM 8.1.1:** `provisioner.openicf-databricks.json`
  activates against the shipped scriptedsql-connector 1.5.20.33; both object
  types (`businessRecord`, `outboundRecord`) registered from one instance;
  all seven Groovy scripts compile against the shipped framework jars
  (compile-checked with the runtime's own groovy 3.0.22 + connector jars).
- **Secret wiring:** tracked config carries only `&{databricks.pat}` /
  `&{databricks.jdbc.url}`; `idm-config/deploy.sh` syncs real values from
  `secrets/databricks.env` into `resolver/boot.properties`.

### Blocker

- **PAT invalid (403 "Invalid access token")** — confirmed independently of
  JDBC via REST (`/api/2.0/preview/scim/v2/Me` → 403). The stored token is
  well-formed (`dapi` + 32 hex) but expired or revoked. **DAN**: mint a fresh
  PAT (Settings → Developer → Access tokens; BI Tools scope preset, 30d) and
  replace `DATABRICKS_PAT` in `secrets/databricks.env`.

### Lab quirk (recorded, not blocking)

- When the connector's Tomcat JDBC pool logs a connection failure, IDM's
  bootstrap log encoder (`JsonEncoder.setDetail`) throws
  `NoClassDefFoundError: org/forgerock/json/resource/ResourceException`
  (class absent from the launcher classpath), and that error **masks the
  real one** in `?_action=test` responses. True causes are visible in
  `logs/openidm.log` throwables with `org.identityconnectors` /
  `org.forgerock.openicf` loggers at DEBUG (enabled in the runtime's
  logback.xml for the spike).

### Next run (once the PAT is replaced)

```bash
databricks/smoke-test.sh                            # SELECT 1 → SMOKE-OK
databricks/apply-sql.sh databricks/sql/001_lab_tables.sql   # tables+CDF+seed
idm-config/deploy.sh                                # re-sync boot.properties
idm-config/acceptance-test.sh                       # full acceptance set
```

Acceptance criteria mapping (plan.md → acceptance-test.sh steps): test (1),
schema visibility (2), search/recon + paging (3), CRUD verified in
Databricks (4), CDF liveSync over out-of-band insert+update+delete (5),
outbound object class on the same instance (6).

### Open questions for the acceptance run

- Does `current_catalog()` default to `workspace` on this Free Edition
  workspace? (DDL and the `TABLES` maps assume it; one-line change if not.)
- Prepared-statement (`?`) support through the Simba driver for
  INSERT/UPDATE/DELETE — expected fine, verified by step 4.
- `DESCRIBE HISTORY` / `table_changes()` through JDBC on serverless —
  verified by step 5.
- Warehouse auto-start latency vs the pool's `validationQuery` timeout on
  cold starts.
