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
- [x] **DAN**: generate PAT → `DATABRICKS_PAT` in `secrets/databricks.env`
      (BI Tools scope preset, 30d). First stored token was already
      expired/revoked (403); fresh mint 2026-09-09 → auth green
- [x] Connectivity smoke test from the lab: `databricks/smoke-test.sh` →
      SMOKE-OK (catalog `workspace`, authed as Dan). Two env findings in
      spike-results.md: quote the JDBC URL in the sourced env file
      (unquoted `;` truncates it — the real cause of driver error 500177),
      and `EnableArrow=0` on the URL (Arrow fetch breaks on Java 21 without
      `--add-opens`)

## Phase 1 — ScriptedSQL spike vs Databricks Free Edition

> ADR-001 closed 2026-09-09: **ScriptedSQL** selected on auth posture (M2M
> with secrets out of config) + config topology, without spiking
> DatabaseTable. This phase validates ScriptedSQL against the Databricks
> driver. Lab auth is a scoped PAT (Free Edition can't do SP OAuth); the
> M2M migration checklist lives in design.md → "Migration: PAT → OAuth M2M".

Setup:
- [x] Run `databricks/sql/001_lab_tables.sql` (tables + CDF + seed rows) —
      applied via `databricks/apply-sql.sh`: schema + 2 tables + 3/2 seeds
- [x] Groovy scripts in `idm-config/script/` (Test, Schema, Search, Sync,
      Create, Update, Delete; modeled on shipped `scripted-sql-with-mysql`
      sample): two object classes (`businessRecord`, `outboundRecord`), CDF
      `_commit_version` sync token, read-only `last_modified` flagged
      NOT_CREATABLE/NOT_UPDATEABLE (business read-only set still TBD);
      compile-checked against the runtime's shipped jars. PAT flows through
      provisioner `username`/`password` properties (encrypted by IDM);
      the customizer script arrives with the M2M migration
- [x] Single `idm-config/conf/provisioner.openicf-databricks.json` (both
      object classes, secrets via `&{databricks.pat}`/`&{databricks.jdbc.url}`);
      `idm-config/deploy.sh` copies config+scripts into `runtime/openidm/`
      and syncs boot.properties — deployed, connector activates in IDM,
      object types registered

Spike execution (acceptance criteria — runner: `idm-config/acceptance-test.sh`):
- [x] `test`: `POST /openidm/system/databricks?_action=test` → ok
- [x] schema visible: both object types exposed from the one instance;
      read-only `last_modified` verified live (client-supplied value on PUT
      discarded, server re-stamps via `current_timestamp()`)
- [x] search/recon: seed rows returned; paging works (LIMIT + record_id
      cookie at `_pageSize=2`)
- [x] create / update / delete via `/openidm/system/databricks/businessRecord`
      → each write cross-checked out-of-band in Databricks over JDBC
- [x] liveSync: CDF token 4 → 7 over out-of-band insert + update **+ delete**
- [x] outbound: seed query + create against
      `/openidm/system/databricks/outboundRecord` on the same instance

**Results recorded: `docs/spike-results.md` — 14/14 PASS, ADR-001 validated.
Phase 1 complete (2026-09-09).**

## Phase 2 — RCS topology rehearsal

- [ ] Download Java RCS (Backstage) → `rcs/`; move connector + driver jars
- [ ] RCS server mode; IDM `provisioner.openicf.connectorinfoprovider.json` → remote
- [ ] Re-run phase-1 acceptance set unchanged

## Phase 3 — real AIC tenant

- [ ] **DAN**: tenant access (dev env); RCS client-mode OAuth creds
- [x] PAT → M2M migration in the lab (design.md checklist, 2026-09-09):
      connector runs as SP `idm-connector-lab` via CustomizerScript +
      encrypted `customSensitiveConfiguration`; IDM holds no PAT
      (boot.properties purged); acceptance 15/15 as the SP, confirmed by
      Databricks query history. Token-lifetime soak: 9/9 probes OK across
      80 min, crossing the 1-hour token boundary (evidence:
      `docs/evidence/soak-20260909-152501.log`). Remaining: optional
      workspace PAT revocation once admin tooling no longer needs it
- [ ] Port provisioners/mappings; ESVs for secrets; re-run acceptance set
      (tenant workspace: recreate SP + grants there per the same checklist)
