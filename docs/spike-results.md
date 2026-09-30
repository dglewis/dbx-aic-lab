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

**Re-run: 15/15** — the read-only enforcement check was added as its own
step. The runner script is the record of the exact commands. Reproduce
anytime with `idm-config/acceptance-test.sh`; each run writes a local
request/response log under `test/runs/` (not tracked).

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

## 2026-09-09 — connector migrated to SP OAuth M2M: 15/15 as the SP

The connector now authenticates as `idm-connector-lab` (design.md
"Credential path, as built"): `CustomizerScript.groovy` assembles
`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret` at init from the encrypted
`customSensitiveConfiguration` propertyBag; `deploy.sh` purges
`databricks.pat` from `boot.properties`, so **IDM holds no PAT at all** —
the SP is the only credential the connector could have used.

Evidence:

- Full suite 15/15 on M2M, IDM log line "Databricks connection set to
  OAuth M2M as service principal <sp-client-id>".
- **Databricks query history** (independent, server-side): 21 recent
  warehouse queries executed by user `<sp-client-id>`
  (the SP) vs 4 by <admin-user> (admin out-of-band tooling).
- The run immediately after IDM restart (6/15): early steps failed transiently
  (cold serverless warehouse + first M2M token exchange while the facade
  initialized; routes 404'd) and the suite self-healed mid-run. Recorded as
  a cold-start characteristic, not a defect: production topologies should
  expect first-connect latency after restart against an auto-stopped
  warehouse.

Toolkit findings baked into the design doc: scripted-sql's customizer is a
plain script body with `configuration` bound (the scripted-REST
`customize { init {…} }` DSL breaks script loading); the ScriptedSQL doc
page omits customizer/customSensitiveConfiguration, but the shipped
`ScriptedSQLConfiguration` inherits both (javap + live probe).

**Token-lifetime soak: 9/9 OK** (`databricks/soak-test.sh`):
probes every 10 min for 80 min (23:25→00:45 UTC), crossing the 1-hour
token boundary with zero failures; pool `maxAge=50min` recycling holds.
Migration checklist complete except optional workspace PAT revocation
(deferred while admin tooling still uses it).

## 2026-09-12 — publish prep: clean-room filter parser, 16/16

Preparing for public sharing surfaced a licensing item: SearchScript's
filter-to-SQL translation was closely adapted from a vendor sample carrying
Ping's proprietary header. Rewritten clean-room (table-driven operator map +
comparator negation, values only ever bound as `?` parameters) and — since
the suite had never exercised a real `_queryFilter` expression — a new check
(3c: `eq` and `sw` operators) now covers it. Suite grew a readiness gate
(polls the connector test action before asserting), which absorbs the known
cold-start 404s after a deploy. Result: **16/16**.
Also this session: personal identifiers scrubbed from docs;
`NOTICE.md`, credential template, and agent guide added. Run logs now stay
local under `test/runs/` (gitignored) rather than being committed.

## 2026-09-29 — baseline blocked: warehouse won't start, PAT invalid

Re-establishing the baseline before Phase 2 (run log
`acceptance-node-2026-09-29T16-34-24.log`, commit `609b961`): `deploy.sh` +
`npm test` → readiness gate timed out after 180 s, **0/16 run**. Isolated
below the connector — not a connector or config fault:

- **Warehouse refuses to start.** SP OAuth token exchange succeeds; the
  warehouse is `STOPPED`, and every start attempt — JDBC `OpenSession` from
  the connector and a `SELECT 1` via the SQL Statement API as the SP —
  returns `400 BAD_REQUEST: Cannot create the resource, please try again
  later`. Databricks-side compute/quota refusal; the SP (`CAN_USE` only)
  cannot see warehouse health details.
- **PAT invalid.** `databricks/smoke-test.sh` and SCIM `/Me` → `403 Invalid
  access token`. The suite's out-of-band checks use this PAT, so they would
  fail even with the warehouse up.
- **Workspace intact.** Read-only UC/REST inspection as the SP: same
  workspace ID as `secrets/databricks.env`; catalog `workspace`, schema
  `idm_lab`, both tables present with CDF enabled; SP grants in place.
  (Owner's UI appeared empty — suspected wrong workspace/account in the
  browser; unconfirmed.)
- Secondary: a scheduler thread logged `NoClassDefFoundError:
  org/forgerock/json/resource/ResourceException` after the hot redeploy
  (IDM up ~17 days). Suspected stale classloader — recheck after restart.

Unblock is owner-side (plan.md → Baseline).

## 2026-09-29 — baseline restored: 16/16, no PAT anywhere

Run log `acceptance-node-2026-09-29T20-12-33.log`. The warehouse accepted
connections again; the out-of-band checks and `JdbcRunner`
(`apply-sql.sh`/`smoke-test.sh`) now authenticate as the service principal
via OAuth M2M, with the PAT only as a fallback (ADR-002). The stale PAT
still present in the local env file was never used — it would have 403'd.
`smoke-test.sh` → SMOKE-OK with `current_user()` = the SP. First
`npm test` still failed its readiness gate on the stale-classloader
`NoClassDefFoundError`; after an IDM restart, **16/16**. Run log checked:
no client secret, token, token endpoint, host or warehouse ID. New offline
unit tests: `npm run test:unit`, 12/12.

## 2026-09-29 — RCS server mode (T1): 16/16, proven remote

Java RCS 1.5.20.36, extracted from the official image, running on the host
JDK 21 in server mode; IDM connects on 8759 (`idm-config/deploy.sh rcs`).

- **16/16** through the RCS (`acceptance-node-2026-09-29T21-19-18.log`,
  profile `rcs`).
- **Proven remote**: with IDM's own scriptedsql and Databricks driver jars
  moved out of the runtime, IDM listed only the RCS-hosted scriptedsql
  1.5.20.36, and the suite passed again **16/16**
  (`acceptance-node-2026-09-29T21-21-26.log`); the RCS connector log shows
  the scripts executing there, and the customizer logged the M2M setup on
  the RCS. Jars restored, `deploy.sh local` → T0 **16/16**
  (`acceptance-node-2026-09-29T21-22-34.log`).
- Credential path unchanged on the RCS: `customSensitiveConfiguration`
  arrives as a `GuardedString` and populates `propertyBag.oauth2` (probe of
  key names/types only).
- IDM 8.1.1 names the SSL flag `useSSL` (docs say `usessl`), confirmed via
  `createConnectorServerCoreConfig`; its interval defaults differ from the
  docs.
- Gotcha: IDM reads `boot.properties` only at startup, so a new
  substitution property (`rcs.key`) needs an IDM restart — until then the
  connectorinfoprovider fails with "Missing config properties".
- Unexplained, not reproduced: the first connector init after an IDM
  restart ran the customizer with an empty `oauth2` bag (warning logged,
  test timed out); it cleared after an RCS restart and did not recur on a
  second IDM restart with the RCS already running. Watch for it.
- Logging: connector/Groovy output lands in `openicf/logs/Connector.log` and
  is also forwarded into IDM's log; the M2M customizer line went to the RCS
  console.
- Run logs checked: no client secret, RCS key, host, warehouse ID or token.

## 2026-09-29 — RCS client mode (T2): 16/16, least-privilege login

The target mode: the RCS (1.5.20.36, host JDK 21) connects out to
`wss://localhost:8443/openicf`; IDM has a `remoteConnectorClients` entry
`rcslocal` (`idm-config/deploy.sh rcs-client`, `rcs/deploy.sh client`).

- **16/16** first with the lab admin login
  (`acceptance-node-2026-09-30T02-04-28.log`), then **16/16** with a
  dedicated login (`acceptance-node-2026-09-30T02-08-07.log`).
- Auth against self-hosted IDM (no AM): basic credentials
  (`connectorserver.principal`/`password`). Without an `openicf` access rule,
  IDM admits any authenticated user and logs "No openicf servlet access rule
  defined, allowing request from openidm-admin". Now: a third STATIC_USER
  login for the shipped internal user `connector-server-client` (password
  from `boot.properties`, only role `internal/role/rcs-rcslocal`) plus an
  access rule `{servlet: openicf, pattern: rcslocal, roles:
  internal/role/rcs-rcslocal}`; IDM's authentication audit shows the RCS
  websockets logging in as `connector-server-client`. A curl probe of the
  endpoint returned 403 for every user — the probe was wrong, not evidence
  either way; the negative test (admin refused) is still open.
- TLS: IDM's self-signed certificate (`CN=localhost`, no SAN) imported into
  the RCS truststore. The RCS sets the JVM-wide truststore from its own, so
  that store must also keep the public CAs the Databricks driver needs.
  A pod will reach IDM under another hostname — Kubernetes needs a cert with
  a matching SAN.
- The vendor start script echoes `OPENICF_OPTS` on `/run`; `rcs/run.sh`
  passes the credentials in a JDK `@argfile` (mode 600) so only its path is
  printed. Password found in neither the RCS console nor IDM's log.
- IDM's client-mode template (`createConnectorServerCoreConfig`) uses
  `useSSL`, as for server mode.
- After a deploy the first connector test can land before the provisioner
  finishes activating ("connector not available"); the suite's readiness
  gate absorbs it.

## 2026-09-29 — RCS pod in minikube (T3): 16/16

One RCS pod (official image `gcr.io/forgerock-io/rcs:1.5.20.36` + our driver,
scripts, properties, logback, truststore), client mode to IDM on the Mac via
`host.minikube.internal`. Cluster: minikube 1.38, vfkit driver, containerd
2.2.1, Kubernetes 1.35.0.

- **16/16** through the pod (`acceptance-node-2026-09-30T02-37-03.log`,
  profile `k8s`); 22 script executions logged in the pod; M2M customizer ran
  in the pod.
- IDM credentials: Kubernetes Secret containing a JDK @argfile, referenced by
  `OPENICF_OPTS` — no password in env, pod log, process list or run log
  (all checked).
- Failures on the way (details in k8s-dev-experience.md): Secret file
  permissions vs non-root uid; StatefulSet not replacing a crash-looping
  pod; TLS handshake failure because IDM's shipped cert is CN=localhost with
  no SAN — fixed with a lab cert (`idm-config/lab-tls-cert.sh`, SAN
  `localhost`, `host.minikube.internal`, `127.0.0.1`).
- The image's default truststore validates Databricks; our `logback.xml`
  puts connector/Groovy output in `kubectl logs`.
- The first TLS attempt from the node to IDM timed out once, then worked; the
  macOS firewall permits Java (IDM) but blocks other listeners by default.

## 2026-09-30 — two RCS pods in a failover group (T3): 16/16

Two pods (`rcs-0`, `rcs-1`) in the StatefulSet, each registering as its own
connector server (`rcs0`, `rcs1` — derived from the pod name, as names must
match `^[a-z0-9]*$`). IDM puts both in the failover group `rcsdatabricks`;
the provisioner's `connectorHostRef` points at the group. Both pods use one
IDM login (role `internal/role/rcs-databricks`). Probes check for an
ESTABLISHED socket to IDM; PodDisruptionBudget `minAvailable: 1`.

- **16/16** through the group with one pod
  (`acceptance-node-2026-09-30T16-39-14.log`) and with two
  (`acceptance-node-2026-09-30T16-41-29.log`), profile `k8s`.
- IDM 8.1.1 reads the group from the top-level key
  `remoteConnectorClientsGroups` (plural). Ping's page shows it inside
  `remoteConnectorClients`; that form was silently ignored ("connector not
  available"). Key name confirmed from IDM's own bundle.
- Probe check: passes on port 8443 (connected), fails on an unused port.

**Pod kill, first pass** (`rcs/k8s/failover-test.sh`; logs
`failover-ops-20260930T164414Z.log`, `failover-livesync-20260930T165023Z.log`):
- IDM saw the killed pod's socket close within ~1 s and sent the next
  request to `rcs1`.
- `rcs1` then failed every read: its JDBC URL had no M2M settings. On a
  freshly started RCS, data operations fail until IDM's connector *test*
  action runs on it once (the test runs the customizer). Reproduced on
  `rcs-0` after a restart: 25 reads over 25 s all failed, then one test call
  fixed it. The suite's readiness gate calls test, which is why earlier runs
  never showed this; it explains the "first-init miss" noted under T1.
- liveSync, pod killed 4 s into a 300,000-row commit: the stored token stayed
  at the baseline (186) — nothing skipped; the next complete run moved it
  to 190. But the interrupted call never returned an error, and the two
  liveSync calls made during the following ~10 minutes hung (IDM logged
  "Failed to find request response target" for each delta). This test was
  not clean — each call overlapped the still-pending one, checks were 5
  minutes apart — so no recovery time is claimed.
- Both open points are recorded as known concerns (plan.md; research doc
  Unknowns #14, #15), not blockers.
