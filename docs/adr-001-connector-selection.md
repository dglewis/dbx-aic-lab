# ADR-001: DatabaseTable vs ScriptedSQL connector selection

**Status:** Accepted (2026-09-09) — **ScriptedSQL**. Decided on decision
inputs (2) and (4) below, ahead of the functional spike; see Decision.
The authentication method itself is recorded in
[ADR-002](adr-002-databricks-authentication.md).

## Context

An ICF connector must perform CRUD and incremental sync against a SQL-accessible
data platform over JDBC. Two bundled connector types can do this: the
config-only DatabaseTable connector and the script-driven ScriptedSQL
(Groovy) connector.

## Comparison

| Criterion | DatabaseTable | ScriptedSQL |
|---|---|---|
| Effort / maintenance | Config only; no code | Groovy script per ICF operation |
| SQL generation | Connector-generated, assumes conventional RDBMS dialect and transaction semantics | Fully authored; any dialect quirk is handled in script |
| Vendor certification | Tested against a fixed list of mainstream RDBMS; anything else is uncertified | Works with any JDBC source by design |
| Object classes per instance | One table per connector instance | Multiple object classes in one connector |
| Per-attribute schema flags (e.g. NOT_UPDATEABLE) | Not expressible; enforce via mappings only | Declared in the schema script |
| Incremental sync | Changelog/timestamp column only; no delete detection | Any token strategy (timestamp, change-data-feed version); deletes detectable if source exposes them |
| **Authentication** | Static credential properties (`username`, `password` — encrypted by IDM on config load) plus the JDBC `url`. Static secret is the natural fit; stronger flows (e.g. OAuth client-credentials) only by embedding secrets in the URL — *outside* the encrypted field | Connection initialization customizable in code (customizer script): secrets sourced from env/vault/ESV at runtime, never stored in connector config; rotation handled at the source; any driver-supported auth flow reachable |

## Authentication posture (generic principle)

A config-only connector limits authentication to what fits its credential
fields. A static bearer secret (password or personal access token) is
encrypted at rest but is long-lived and rotated manually. Service-account
OAuth (client-credentials) is preferable — short-lived tokens, non-human
identity, least-privilege grants — but reaching it through a config-only
connector typically means placing the client secret in plain connector
config, which can be a net loss. A scripted connector makes strong auth the
natural path because credential acquisition is code: the secret lives in a
secret store, not the config, and rotation requires no connector change.

If organizational policy requires service-account OAuth with clean secret
handling, that requirement alone can decide for the scripted connector even
if the config-only connector passes all functional tests.

## Decision inputs

1. Functional spike: does the config-only connector's generated SQL and
   transaction handling survive the target's JDBC driver? (CRUD + liveSync)
2. Auth policy: is a static encrypted secret acceptable, or is
   service-account OAuth with secrets kept out of config required?
3. Operational gaps: delete detection and per-attribute read-only
   enforcement needs, weighed against the cost of owning scripts.
4. Config topology: one system-named provisioner serving both directions
   (scripted, multiple object classes) vs one instance per table forced by
   the config-only connector — doubled connection pools, credentials
   config, and lifecycle to manage.

A pass on (1) with a strict answer on (2) or (3) still selects ScriptedSQL.

## Decision

**ScriptedSQL**, decided without running the DatabaseTable spike:

1. **Auth policy (input 2) answers strictly.** The production target is
   service-principal OAuth M2M with secrets kept out of connector config.
   DatabaseTable can reach M2M only by embedding `OAuth2ClientId`/`OAuth2Secret`
   in the JDBC `url` property — plain config, outside IDM's encrypted
   credential fields. ScriptedSQL sources credentials at runtime in the
   customizer script (env/ESV/vault), so rotation never touches config. Per
   the rule above, this alone selects ScriptedSQL.
2. **Config topology (input 4).** One system-named provisioner
   (`provisioner.openicf-databricks.json`) serves both tables as object
   classes in a single connector instance; DatabaseTable would force two
   instances with doubled pools, credentials, and lifecycle.
3. Supporting: CDF-based sync detects deletes (DatabaseTable's
   changelog-column liveSync cannot); per-attribute `NOT_UPDATEABLE`
   enforcement lives in the connector schema, not only in mappings.

**Lab-auth finding (2026-09-09) — RETRACTED same day:** this ADR originally
claimed Free Edition cannot do service-principal OAuth (sourced from a
community thread, not tested). **Empirically disproven on the lab
workspace:** a service principal was created via the workspace SCIM API, an
OAuth secret generated in the workspace UI (Identity and access → Service
principals → Secrets), the client-credentials exchange at
`https://<host>/oidc/v1/token` returned a 1-hour `all-apis` Bearer token,
and `SELECT current_user()` over JDBC with
`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret` executed as the SP after
least-privilege grants (warehouse `CAN USE`; UC `USE CATALOG`/`USE SCHEMA`
+ `SELECT, MODIFY` on the two lab tables). Evidence in
docs/spike-results.md. Free Edition still has no account *console*, but
workspace-level SP identity + OAuth secrets are sufficient for M2M.
Consequence: the PAT (BI Tools scope, 30d) is merely the connector's
*current* lab auth; the M2M migration checklist
([design.md, "Setting up OAuth M2M"](design.md#setting-up-oauth-m2m-service-principal)) is executable in the
lab now rather than deferred to a paid workspace. Lesson recorded: vendor
limits get verified empirically before they decide anything.

Functional acceptance (input 1) still runs — now to validate ScriptedSQL
against the Databricks driver, not to choose between connectors.

## Citations

Claims above are verified against official documentation and vendor-shipped
artifacts in this repo's IDM 8.1.1 runtime:

- **Single table per instance; changelog-column liveSync; no delete detection**
  — [Database Table connector reference](https://docs.pingidentity.com/openicf/connector-reference/dbtable.html):
  "lets you provision to a single table in a JDBC database"; "supports liveSync
  for create and update operations only. To detect deletes in the database you
  must run a full reconciliation."
- **DatabaseTable tested-database list** (MySQL, PostgreSQL, Oracle 11gR2+,
  SQL Server 2012+; paging unsupported elsewhere) — same page.
- **DatabaseTable config surface** (`url`, `driverClassName`, `table`,
  `keyColumn`, `username`, `password`, `changeLogColumn`) — same page.
- **IDM encrypts connector passwords on config load** —
  [PingIDM 8.1 Security Guide, Secure IDM data](https://docs.pingidentity.com/pingidm/8.1/security-guide/chap-data.html):
  sensitive values (e.g. passwords) in configuration are encrypted when IDM
  first reads the file.
- **ScriptedSQL: one Groovy script per ICF operation; JDBC url/username/password
  properties; embedded Tomcat JDBC pool** —
  [Scripted SQL connector reference](https://docs.pingidentity.com/openicf/connector-reference/scripted-sql.html).
- **Customizer script exists as a toolkit config property**
  (`customizerScriptFileName`) —
  [Groovy Connector Toolkit reference](https://docs.pingidentity.com/openicf/connector-reference/groovy.html).
  Vendor-shipped example implementing OAuth client-credentials in a customizer:
  `runtime/openidm/samples/scripted-rest-with-dj/tools/CustomizerScript.groovy`
  (imports `CLIENT_ID`, `CLIENT_SECRET`, `GRANT_TYPE`, `OAUTH_REQUEST`).
- **Per-attribute schema flags in scripted schema** — vendor-shipped sample
  `runtime/openidm/samples/scripted-sql-with-mysql/tools/SchemaScript.groovy`
  (imports/uses `AttributeInfo.Flags`: `REQUIRED`, `NOT_READABLE`,
  `NOT_RETURNED_BY_DEFAULT`); the full `AttributeInfo$Flags` enum in the
  shipped `bundle/connector-framework-1.5.20.33.jar` is `REQUIRED`,
  `MULTIVALUED`, `NOT_CREATABLE`, `NOT_UPDATEABLE`, `NOT_READABLE`,
  `NOT_RETURNED_BY_DEFAULT`.
- **Free Edition: no account console; login auth limited to email OTP and
  Google/Microsoft sign-in** —
  [Free Edition limitations](https://docs.databricks.com/aws/en/getting-started/free-edition-limitations).
  A [community thread](https://community.databricks.com/t5/administration-architecture/zerobus-ingestion-fails-in-databricks-free-edition-using-service/td-p/161228)
  inferred SP OAuth was therefore unavailable — **disproven empirically on
  this project's workspace 2026-09-09** (see the retracted lab-auth finding
  above): workspace-level SP creation, OAuth secret generation, and M2M
  token exchange all work on Free Edition.
- **OAuth M2M: access tokens valid one hour; scoped secrets cap minted-token
  scope** —
  [OAuth M2M authorization](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m).
- **Driver auth properties for the JDBC source used in this project**
  (PAT: `AuthMech=3;UID=token;PWD=<token>`; OAuth M2M:
  `AuthMech=11;Auth_Flow=1;OAuth2ClientId=…;OAuth2Secret=…`, settable in the
  JDBC URL) —
  [Databricks JDBC Driver (OSS) authentication](https://docs.databricks.com/aws/en/integrations/jdbc-oss/authentication).

Note: automatic OAuth token refresh is documented explicitly for the driver's
U2M flow; the M2M flow's refresh behavior is not explicitly documented and is
not relied on by this ADR.
