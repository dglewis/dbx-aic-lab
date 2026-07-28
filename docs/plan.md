# Build plan

`[x]` done · `[ ]` open · **DAN** = needs Dan (account/credential actions)

## Phase 0 — lab infrastructure ✅

- [x] Repo + layout (`runtime/` disposable, `secrets/` gitignored, tracked config dirs)
- [x] IDM 8.1.1 extracted; DS 8.1.1 set up (`idm-repo` profile, domain
      `forgerock.com` → `dc=openidm,dc=forgerock,dc=com`) and running on 31389
- [x] Split JDKs: brew `openjdk@21` (IDM) / `openjdk@25` (DS)
- [x] IDM `ACTIVE_READY` on 8443; Databricks JDBC 2.7.3 in `openidm/lib/`, clean load
- [x] ADR-001 (connector selection criteria, cited)

Databricks tenant connectivity (infrastructure, not spike work):
- [ ] **DAN**: sign up for Free Edition —
      <https://login.databricks.com/?intent=CE_SIGN_UP> (email OTP, Google, or
      Microsoft; provisions a serverless workspace automatically)
- [ ] **DAN**: warehouse connection details (SQL Warehouses → warehouse →
      **Connection details**: server hostname + HTTP path) and a PAT
      (Settings → **Developer** → Access tokens) → `secrets/databricks.env`
      (`DATABRICKS_HOST`, `DATABRICKS_HTTP_PATH`, `DATABRICKS_PAT`)
- [ ] Connectivity smoke test from the lab: standalone JDBC `SELECT 1` through
      `databricks-jdbc-2.7.3.jar` (proves network + auth + driver before any
      connector is involved)

## Phase 1 — DatabaseTable spike vs Databricks Free Edition

Setup:
- [ ] Run `databricks/sql/001_lab_tables.sql` (tables + CDF + seed rows)
- [ ] Fill provisioner placeholders from `secrets/databricks.env`; copy
      `idm-config/conf/provisioner.openicf-databricksInbound.json` →
      `runtime/openidm/conf/`; add `databricks.pat` to `resolver/boot.properties`

Spike execution (acceptance criteria — all against the inbound table):
- [ ] `test`: `POST /openidm/system/databricksInbound?_action=test` → ok
- [ ] schema read: `GET /openidm/system/databricksInbound/account/_schema` sane
- [ ] search/recon: query returns seed rows; paging behavior noted (`disablePaging` if needed)
- [ ] create / update / delete via `/openidm/system/databricksInbound/account` →
      verified in Databricks
- [ ] liveSync: `changeLogColumn=last_modified` picks up out-of-band insert+update
- [ ] outbound instance: same `test` + create against `outbound_records`

Fallback triggers (any → switch to ScriptedSQL, per ADR-001):
- generated SQL rejected by Databricks dialect (quoting, paging, prepared stmts)
- transaction/commit calls fail against auto-commit-only warehouse
- three-part table naming (`catalog.schema.table`) unsupported by `table` property
- org auth bar requires M2M with secrets out of config

Record results in `docs/spike-results.md` → close ADR-001.

## Phase 2 — RCS topology rehearsal

- [ ] Download Java RCS (Backstage) → `rcs/`; move connector + driver jars
- [ ] RCS server mode; IDM `provisioner.openicf.connectorinfoprovider.json` → remote
- [ ] Re-run phase-1 acceptance set unchanged

## Phase 3 — real AIC tenant

- [ ] **DAN**: tenant access (dev env); RCS client-mode OAuth creds
- [ ] **DAN**: Databricks service principal (M2M) + grants on the two tables
- [ ] Port provisioners/mappings; ESVs for secrets; re-run acceptance set
