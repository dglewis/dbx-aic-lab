# ADR-001: DatabaseTable vs ScriptedSQL connector selection

**Status:** Open — decided by spike results (see README "Spike question").

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

A pass on (1) with a strict answer on (2) or (3) still selects ScriptedSQL.

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
- **Driver auth properties for the JDBC source used in this project**
  (PAT: `AuthMech=3;UID=token;PWD=<token>`; OAuth M2M:
  `AuthMech=11;Auth_Flow=1;OAuth2ClientId=…;OAuth2Secret=…`, settable in the
  JDBC URL) —
  [Databricks JDBC Driver (OSS) authentication](https://docs.databricks.com/aws/en/integrations/jdbc-oss/authentication).

Note: automatic OAuth token refresh is documented explicitly for the driver's
U2M flow; the M2M flow's refresh behavior is not explicitly documented and is
not relied on by this ADR.
