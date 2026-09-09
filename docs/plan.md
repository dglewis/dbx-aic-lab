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
- [x] **DAN**: Free Edition workspace signed up; `secrets/databricks.env`
      created (host, HTTP path, OAuth URL, JDBC URL, workspace ID)
- [ ] **DAN**: generate PAT → `DATABRICKS_PAT` in `secrets/databricks.env`.
      **Scope: choose the `BI Tools` preset** — docs: "Select BI Tools for
      tools that connect to Databricks SQL warehouses"; a JDBC client is
      exactly that class. (Manual-scope equivalent under Other APIs: `sql`.)
      Lifetime: 30d covers the spike; Free Edition, non-production.
- [ ] Connectivity smoke test from the lab: standalone JDBC `SELECT 1` through
      `databricks-jdbc-2.7.3.jar` (proves network + auth + driver before any
      connector is involved)

## Phase 1 — ScriptedSQL spike vs Databricks Free Edition

> ADR-001 closed 2026-09-09: **ScriptedSQL** selected on auth posture (M2M
> with secrets out of config) + config topology, without spiking
> DatabaseTable. This phase validates ScriptedSQL against the Databricks
> driver. Lab auth is a scoped PAT (Free Edition can't do SP OAuth); the
> M2M migration checklist lives in design.md → "Migration: PAT → OAuth M2M".

Setup:
- [ ] Run `databricks/sql/001_lab_tables.sql` (tables + CDF + seed rows)
- [ ] Groovy scripts in `idm-config/script/` (Test, Schema, Search, Sync,
      Create, Update, Delete + Customizer; model on shipped
      `scripted-sql-with-mysql` sample): two object classes
      (`businessRecord`, `outboundRecord`), CDF `_commit_version` sync token,
      `NOT_UPDATEABLE` flags on the read-only set
- [ ] Single `idm-config/conf/provisioner.openicf-databricks.json` (both
      object classes); customizer reads `&{databricks.pat}` — add to
      `resolver/boot.properties`; copy config+scripts into `runtime/openidm/`

Spike execution (acceptance criteria):
- [ ] `test`: `POST /openidm/system/databricks?_action=test` → ok
- [ ] schema read: `GET /openidm/system/databricks/businessRecord/_schema`
      sane, read-only flags present
- [ ] search/recon: query returns seed rows; paging behavior noted
- [ ] create / update / delete via `/openidm/system/databricks/businessRecord`
      → verified in Databricks
- [ ] liveSync: CDF token picks up out-of-band insert + update **+ delete**
- [ ] outbound: same `test` + create against
      `/openidm/system/databricks/outboundRecord`

Record results in `docs/spike-results.md` (ADR-001 already closed; results
validate the choice or reopen it).

## Phase 2 — RCS topology rehearsal

- [ ] Download Java RCS (Backstage) → `rcs/`; move connector + driver jars
- [ ] RCS server mode; IDM `provisioner.openicf.connectorinfoprovider.json` → remote
- [ ] Re-run phase-1 acceptance set unchanged

## Phase 3 — real AIC tenant

- [ ] **DAN**: tenant access (dev env); RCS client-mode OAuth creds
- [ ] **DAN**: paid/standard Databricks workspace (Free Edition can't do SP
      OAuth) — then run the full PAT → M2M checklist in design.md
      ("Migration: PAT → OAuth M2M"): service principal, scoped OAuth
      secret, least-privilege grants, customizer swap, token-refresh soak
      test, PAT revoked
- [ ] Port provisioners/mappings; ESVs for secrets; re-run acceptance set
