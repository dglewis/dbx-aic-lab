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
| **Authentication** | Three knobs: `user`, `password` (encrypted at rest), URL template. Static secret is the natural fit; stronger flows (e.g. OAuth client-credentials) only by embedding secrets in the URL template — *outside* the encrypted field | DataSource built/configured in code (customizer script): secrets sourced from env/vault/ESV at runtime, never stored in connector config; rotation handled at the source; any driver-supported auth flow reachable |

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
