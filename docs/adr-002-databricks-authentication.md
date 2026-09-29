# ADR-002: Databricks authentication — OAuth M2M, PAT optional

**Status:** Accepted (2026-09-29).

## Context

Everything in this lab that talks to Databricks has to authenticate: the
connector (over JDBC), the admin tooling (SQL setup, smoke and soak tests),
and the acceptance suite's out-of-band checks (SQL Statement Execution REST
API). Databricks offers two workspace-level mechanisms that fit
unattended use:

- **OAuth machine-to-machine (M2M)** — a service principal exchanges a
  client ID and OAuth secret for a short-lived access token (client
  credentials at `https://<workspace>/oidc/v1/token`).
- **Personal access token (PAT)** — a static bearer token issued to a user
  or service principal.

## Decision

**OAuth M2M as a service principal is the authentication method** for the
connector and, by default, for all lab tooling and tests. **A PAT remains a
supported, optional alternative** wherever the Databricks APIs accept one; it
is never required to run the lab.

## Reasons

| | OAuth M2M (service principal) | PAT |
|---|---|---|
| Token lifetime | Access tokens valid one hour, re-minted automatically | Long-lived; lifetime set at creation (auto-revoked after 90 days unused) |
| Identity | Non-human service principal, independent of any person | Issued to an identity; commonly a person's |
| Least privilege | Grants scoped to exactly what the SP needs (warehouse `CAN USE`, UC `SELECT`/`MODIFY` on specific tables) | Carries the issuing identity's permissions, narrowed only by token scope |
| Rotation | Rotate the OAuth secret at the source; connector config unchanged | Manual reissue and redistribution |
| Where the secret lives | IDM-encrypted `customSensitiveConfiguration` (lab) or an ESV (AIC); only short-lived tokens reach the wire | The bearer token itself is the credential on every request |
| Vendor guidance | "Databricks uses OAuth 2.0 as the preferred protocol for service principal authorization and authentication outside of the UI" | "Where possible, Databricks recommends using OAuth instead of PATs" |

**Connector support shaped the connector choice.** The two bundled JDBC
connectors differ in how cleanly they reach M2M
([ADR-001](adr-001-connector-selection.md)):

| | Static secret (PAT) | OAuth M2M |
|---|---|---|
| DatabaseTable | Clean — the token goes in the IDM-encrypted `password` field | Only by putting `OAuth2ClientId`/`OAuth2Secret` in the JDBC `url` — plain config, outside encryption |
| ScriptedSQL | Supported | Clean — the customizer script assembles M2M at init from the IDM-encrypted `customSensitiveConfiguration` (an ESV in AIC) |

Requiring M2M with the secret kept encrypted therefore selects ScriptedSQL.

A PAT stays in scope because it is the lowest-friction way to reach a
workspace for ad-hoc administration and diagnostics, and some environments
may accept it. It is an opt-in, never a dependency.

## Consequences

- The connector authenticates only via M2M, assembled by
  `CustomizerScript.groovy` from the encrypted `customSensitiveConfiguration`
  ([design.md → "Credential path"](design.md#credential-path-scriptedsql-as-built)).
  `deploy.sh` keeps no PAT in `boot.properties`.
- Lab tooling and the acceptance suite must work with the service principal
  alone; a PAT, when present, is an alternative credential, not a
  prerequisite. Tracked in [plan.md](plan.md) (G0).
- The service principal needs its own least-privilege grants per workspace;
  setup steps are in [design.md → "Setting up OAuth M2M"](design.md#setting-up-oauth-m2m-service-principal).
- Pooled JDBC connections must not outlive the one-hour token: pool
  `maxAge` is 50 minutes, because the driver's M2M token-refresh behaviour
  over a held-open connection is not documented.

## Citations

- [Databricks — OAuth M2M authorization](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-m2m):
  preferred protocol for service principals; one-hour access tokens;
  workspace token endpoint `/oidc/v1/token`.
- [Databricks — personal access tokens](https://docs.databricks.com/aws/en/dev-tools/auth/pat):
  OAuth recommended over PATs; PATs unused for 90 days are revoked; one
  workspace per PAT.
- [Databricks JDBC Driver (OSS) — authentication](https://docs.databricks.com/aws/en/integrations/jdbc-oss/authentication):
  PAT `AuthMech=3;UID=token;PWD=<token>`; OAuth M2M
  `AuthMech=11;Auth_Flow=1;OAuth2ClientId=…;OAuth2Secret=…`.
- [ADR-001](adr-001-connector-selection.md) — why reaching M2M cleanly
  required the scripted connector.
