# Agent guide — db-conn

Context for AI coding agents (Claude Code, Cursor, etc.) working in this repo.

## What this is

A spike lab proving a bidirectional ICF connector between Databricks and
PingIDM/AIC. Read in this order before changing anything:
`docs/adr-001-connector-selection.md` → `docs/design.md` → `docs/plan.md` →
`docs/spike-results.md`. Phase 1 is complete; Phase 2 (RCS topology) is next.

## Hard rules

1. **Read the official, version-exact docs before setup/config work.** This
   project was repeatedly burned by pattern-matching from older releases and
   once by trusting a community thread over a live test. When a capability
   claim gates a decision and a cheap empirical test exists, run the test.
2. **Secrets never enter tracked files or command output.** Real credentials
   live only in `secrets/databricks.env` (gitignored; template:
   `secrets/databricks.env.example`) and the runtime's `boot.properties`.
   Tracked config carries `&{property}` placeholders only. Evidence loggers
   must redact hosts and never log Authorization headers.
3. **`runtime/` is disposable and untracked** — extracted vendor software
   plus live state. Never commit from it; `idm-config/deploy.sh` is the only
   way config reaches it. Tracked config in `idm-config/` is the source of
   truth; do not hand-edit the runtime copies except for throwaway probes.
4. **Ping vendor code stays out.** No copying from `runtime/openidm/samples/`
   (proprietary license headers) — scripts are written clean-room against the
   documented toolkit API. See `NOTICE.md`.
5. **Commits: only when the user says so.** Atomic (one logical change),
   plain imperative subject lines, no conventional-commit prefixes.
6. **Evidence discipline:** every acceptance/soak run writes a raw
   request/response log to `test/runs/` (gitignored, local only) with the
   commit in the header. Check claims of "it works" against a run log;
   record the result in `docs/spike-results.md`, not the log itself.

## Conventions

- Provisioners are named for the **system** (`provisioner.openicf-databricks.json`),
  never for a flow direction; one instance serves both object classes
  (`businessRecord`, `outboundRecord` — dataset-named).
- Sync token = Delta CDF `_commit_version` (Long). Deletes are detected.
- Timestamps interchange as `yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` (UTC).
- Groovy SQL: build statements as plain String concatenation with `?`
  parameters — GString interpolation becomes prepared-statement params,
  which breaks identifiers. `table_changes()` args cannot be parameters.
- Connector auth is OAuth M2M assembled by `CustomizerScript.groovy` from
  the encrypted `customSensitiveConfiguration` property. The scripted-sql
  customizer is a **plain script body** with `configuration` bound — the
  scripted-REST `customize { init {…} }` DSL breaks script loading.
- Known gotchas: JDBC URL needs `EnableArrow=0` on Java 17+; values with
  `;` in the sourced env file must be double-quoted; after deploy/restart
  the first M2M connect against a cold warehouse 404s routes until the pool
  establishes (the test suite's readiness gate handles this).

## Verify your changes

```bash
# Lab up? (DS on 31389, IDM on 8443 — see README runbook)
curl -k -u openidm-admin:openidm-admin https://localhost:8443/openidm/info/ping
idm-config/deploy.sh                  # push tracked config to runtime
cd test && npm test                   # 16 checks; writes test/runs/ + JUnit XML
```

`idm-config/acceptance-test.sh` is the zero-dependency smoke fallback;
`databricks/smoke-test.sh` isolates driver/network/auth below the connector.
