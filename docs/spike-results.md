# Spike results — ScriptedSQL vs Databricks Free Edition

Running log of Phase-1 acceptance evidence (docs/plan.md). ADR-001 already
selected ScriptedSQL; these results validate the choice or reopen it.

## 2026-09-09 — infrastructure built and wired; blocked on fresh PAT

### Verified working

- **JDBC URL / 500177 root cause (corrected same day):** driver error
  500177 "Error getting http path from connection string" was NOT the URL
  format — the `/default` path segment parses fine (retested explicitly).
  The real bug: `secrets/databricks.env` is `source`d by the lab scripts,
  and the URL's **unquoted semicolons** truncated the value at `:443`,
  discarding `httpPath`. Fix: the `DATABRICKS_JDBC_URL` value is now
  double-quoted in the env file. Lesson: a shell-sourced env value
  containing `;` must be quoted.
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

### Blocker — resolved same day

- **PAT invalid (403 "Invalid access token")** — confirmed independently of
  JDBC via REST (`/api/2.0/preview/scim/v2/Me` → 403). The stored token was
  well-formed (`dapi` + 32 hex) but expired or revoked. Dan minted a fresh
  PAT (BI Tools scope, 30d) → auth green.

### Lab quirk (recorded, not blocking)

- When the connector's Tomcat JDBC pool logs a connection failure, IDM's
  bootstrap log encoder (`JsonEncoder.setDetail`) throws
  `NoClassDefFoundError: org/forgerock/json/resource/ResourceException`
  (class absent from the launcher classpath), and that error **masks the
  real one** in `?_action=test` responses. True causes are visible in
  `logs/openidm.log` throwables with `org.identityconnectors` /
  `org.forgerock.openicf` loggers at DEBUG (enabled in the runtime's
  logback.xml for the spike).

## 2026-09-09 (fresh PAT) — ACCEPTANCE RUN: 14/14 PASS

**Evidence:** every raw REST/SQL response of the (re-)run is captured in
[`evidence/acceptance-20260909-143900.log`](evidence/acceptance-20260909-143900.log)
(15/15 on the evidenced re-run — the read-only enforcement check was added
as its own step). The runner script *is* the record of the exact commands;
the log records what IDM and Databricks actually returned, timestamped,
with the repo commit noted in its header. Reproduce anytime with
`idm-config/acceptance-test.sh` — each run writes a fresh log under
`docs/evidence/`.

Chain: `smoke-test.sh` → `apply-sql.sh 001_lab_tables.sql` → `deploy.sh` →
IDM restart → `acceptance-test.sh`, all against the live warehouse:

| # | Criterion | Result |
|---|---|---|
| 1 | `system/databricks?_action=test` | PASS |
| 2 | Both object classes exposed from one instance | PASS |
| 3 | Search returns seed rows; paging cookie at `_pageSize=2` | PASS ×2 |
| 4 | Create/read/update/delete via IDM REST, each write verified out-of-band in Databricks over JDBC | PASS ×7 |
| 5 | liveSync: CDF token advanced 4 → 7 over out-of-band insert + update + **delete** | PASS |
| 6 | Outbound object class: seed query + create on the same connector | PASS ×2 |

**ScriptedSQL vs the Databricks JDBC driver is validated — ADR-001's
selection holds.** Delete detection via CDF works (the DatabaseTable
changelog approach could not have passed step 5).

Environment facts confirmed in the run:

- `current_catalog()` = `workspace` on this Free Edition workspace —
  DDL and script `TABLES` maps correct as written.
- Prepared statements (`?` params) work through the driver for
  SELECT/INSERT/UPDATE/DELETE (steps 3–4).
- `DESCRIBE HISTORY` and `table_changes()` work over JDBC against the
  serverless warehouse (step 5).
- Cold-start latency was no issue in this run; revisit only if the pool's
  `validationQuery` ever times out on a cold warehouse.

### New finding — Arrow result fetch vs modern JVMs: `EnableArrow=0`

With auth working, the driver's Arrow-based result fetch crashes on Java 21
(`InaccessibleObjectException: module java.base does not "opens java.nio"`)
unless the JVM runs with `--add-opens=java.base/java.nio=ALL-UNNAMED`.
Rather than patching JVM flags into IDM's startup (and later the RCS), the
connection property **`EnableArrow=0`** is appended to the JDBC URL — the
driver falls back to its non-Arrow fetch path everywhere, no JVM changes
anywhere. Perf cost is irrelevant at lab row counts; revisit for production
volumes (the trade-off then moves to `--add-opens` on the RCS host JVM).

Also fixed: `DATABRICKS_JDBC_URL` in `secrets/databricks.env` must be
double-quoted — the lab scripts `source` the file, and unquoted `;` in the
value truncates it (the true root cause of the earlier 500177).

### Phase 1 status: **complete**

Next: Phase 2 (RCS topology rehearsal) — re-run this same acceptance set
through a local Java RCS in server mode, unchanged.

## 2026-09-09 — CORRECTION: SP OAuth M2M works on Free Edition

Dan challenged the ADR-001 claim that Free Edition cannot do
service-principal OAuth (his workspace UI offered SP creation). Verified
end to end on the lab workspace, disproving the claim:

1. **SP created** via workspace SCIM API
   (`POST /api/2.0/preview/scim/v2/ServicePrincipals`):
   `idm-connector-lab`, application ID
   `<sp-client-id>`, entitlement
   `databricks-sql-access`. (The workspace-level secrets REST endpoint
   `POST /api/2.0/service-principals/{id}/credentials/secrets` returned
   404 here — the UI path is what works on Free Edition.)
2. **OAuth secret generated by Dan in the workspace UI** (Identity and
   access → Service principals → Secrets → Generate secret).
3. **Client-credentials exchange** at `https://<host>/oidc/v1/token`
   (basic auth client_id:secret, `grant_type=client_credentials`,
   `scope=all-apis`) → Bearer token, `expires_in: 3600`.
4. **Identity confirmed:** `GET /api/2.0/preview/scim/v2/Me` with the
   token returns the service principal.
5. **Grants:** warehouse `CAN_USE` (permissions API) + UC
   `USE CATALOG`/`USE SCHEMA`/`SELECT, MODIFY` on the two lab tables
   (GRANT statements over JDBC as admin).
6. **JDBC as the SP:** URL with
   `AuthMech=11;Auth_Flow=1;OAuth2ClientId=…;OAuth2Secret=…;EnableArrow=0`
   → `SELECT current_user()` returned the SP's application ID and read
   `business_records` (3 rows). Driver-native M2M works.

ADR-001's lab-auth finding is retracted in place; the design doc's
migration checklist steps 1–3 are marked done for the lab. The connector
still runs on the PAT — executing the remaining migration steps
(customizer script, secret into boot.properties/ESV path, soak test past
the 1-hour token lifetime, PAT revocation) is now possible in the lab and
is an open decision.

Root cause of the wrong claim: trusted a community-thread inference
instead of testing. Vendor limits get verified empirically from now on.
