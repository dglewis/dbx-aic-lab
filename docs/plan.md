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
> driver. Auth is OAuth M2M ([ADR-002](adr-002-databricks-authentication.md));
> the setup checklist lives in design.md → "Setting up OAuth M2M".

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

Test harness (2026-09-09): acceptance suite ported to Node/Vitest in
`test/` — 15/15 on first run. IDM REST assertions; out-of-band checks via
the Databricks SQL Statement Execution REST API (vendor-native, independent
of the connector's JDBC path); env profiles `lab`/`tenant` so the same
suite runs against AIC in phase 3; local run logs to `test/runs/`, JUnit XML
for CI. `idm-config/acceptance-test.sh` retained as the zero-dependency
smoke fallback; `databricks/smoke-test.sh` stays the same-driver
diagnostic.

## Phase 2 — RCS in client mode, plain JVM then Kubernetes

**Client mode is the target**: the RCS connects out to IDM/AIC. AIC supports
only client mode, and the Kubernetes design uses it. Server mode (IDM
connects in to the RCS) has no production use for this project; it was run
once as a stepping stone and proved the connector works when hosted on an
RCS.

Steps run in order; each must pass the unchanged acceptance suite before
the next adds a layer, so a failure can only come from the layer just
introduced. Earlier steps stay runnable — the lab keeps both the plain-JVM
and the Kubernetes path. Research, open questions and validation detail:
[rcs-kubernetes-research.md](rcs-kubernetes-research.md). Development
friction on each path goes in [k8s-dev-experience.md](k8s-dev-experience.md).

Baseline — connector in IDM (T0) ✅ 2026-09-29:
- [x] SQL warehouse back up (was refusing to start with `400 Cannot create
      the resource`)
- [x] Suite's out-of-band checks and `JdbcRunner` (`apply-sql.sh`,
      `smoke-test.sh`) authenticate as the service principal, PAT optional
      ([ADR-002](adr-002-databricks-authentication.md)); unit-tested
      (`npm run test:unit`, 12 checks, no network/secrets)
- [x] IDM restarted (cleared the stale-classloader `NoClassDefFoundError`),
      `deploy.sh`, `npm test` **16/16** — no PAT used anywhere

Stepping stone — RCS on the Mac, server mode (T1) ✅ 2026-09-29 (not pursued further):
- [x] RCS 1.5.20.36 extracted from the official image → `rcs/openicf/`
      (gitignored) by `rcs/fetch-rcs.sh`; JDK 21
- [x] `rcs/` tooling (tracked, our own files): `conf/ConnectorServer.properties`,
      `deploy.sh`, `run.sh`; `idm-config/deploy.sh rcs` points IDM's
      provisioner at the RCS (`connectorHostRef`, RCS-side `scriptRoots`)
- [x] Proven remote: with IDM's scriptedsql + driver jars removed, IDM lists
      only the RCS connector, connector test ok, 16/16; scripts and the M2M
      customizer execute in the RCS
- [x] `PROFILE=rcs` → **16/16**; switching back (`deploy.sh local`) → T0 16/16

RCS on the Mac, client mode (T2) — next:
- [ ] IDM `remoteConnectorClients`; RCS connects to `wss://localhost:8443/openicf`
      and authenticates to IDM (no AM locally); trusts IDM's certificate
- [ ] `PROFILE=rcs-client` → 16/16
- [ ] Negatives: wrong credentials, RCS kill/recovery, script-edit reload;
      token-boundary soak through the RCS

Connector hardening (any topology; design.md → "Sync / change detection"):
- [ ] `SyncScript`: fail loudly when the stored token exceeds the table's
      latest version (table recreated) instead of resetting silently
- [ ] `SyncScript`: resume at `token` and skip already-applied rows, so a
      poll failing mid-commit can't skip the rest of that commit

Kubernetes — one pod in minikube, client mode (T3):
- [ ] Install `vfkit`; delete the stale docker-driver minikube profile;
      cluster per README runbook (verify against minikube docs first)
- [ ] Dockerfile `FROM gcr.io/forgerock-io/rcs:1.5.20.36` + our files;
      `minikube image build`; manifests written from scratch
- [ ] Own `logback.xml` so connector/Groovy logs reach stdout
- [ ] `PROFILE=k8s` → 16/16

Kubernetes — high availability (T3, 2 replicas):
- [ ] StatefulSet, Secrets as files, probes, PodDisruptionBudget, IDM
      failover group
- [ ] Pod kill mid-recon/liveSync: error surfaced, failover time, sync-token
      consistency
- [ ] Record results; decide StatefulSet/naming/algorithm → ADR-003

## Phase 3 — real AIC tenant

- [ ] **DAN**: tenant access (dev env); RCS client-mode OAuth creds
- [x] OAuth M2M in the lab (design.md → "Setting up OAuth M2M", 2026-09-09):
      connector runs as SP `idm-connector-lab` via CustomizerScript +
      encrypted `customSensitiveConfiguration`; IDM holds no PAT
      (boot.properties purged); acceptance 15/15 as the SP, confirmed by
      Databricks query history. Token-lifetime soak: 9/9 probes OK across
      80 min, crossing the 1-hour token boundary
- [ ] Port provisioners/mappings; ESVs for secrets; re-run acceptance set
      (tenant workspace: recreate SP + grants there per the same checklist)
- [ ] Managed Kubernetes dev cluster on the client's cloud (provider-neutral
      design; per-provider overlay for secret store + pod identity — see
      design.md → "Cloud-provider neutrality"); private registry, amd64 image
- [ ] Register RCS names + dedicated OAuth clients and access rules in AIC;
      `PROFILE=tenant` → 16/16
- [ ] Websocket idle survival through the provider's egress (soak)
- [ ] Ask Ping: redistribution terms for a derived RCS image
