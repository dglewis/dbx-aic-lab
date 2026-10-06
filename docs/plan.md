# Build plan

`[x]` done · `[ ]` open

## Phase 0 — lab infrastructure ✅

- [x] Repo + layout (`runtime/` disposable, `secrets/` gitignored, tracked config dirs)
- [x] IDM 8.1.1 extracted; DS 8.1.1 set up (`idm-repo` profile, domain
      `forgerock.com` → `dc=openidm,dc=forgerock,dc=com`) and running on 31389
- [x] Split JDKs: brew `openjdk@21` (IDM) / `openjdk@25` (DS)
- [x] IDM `ACTIVE_READY` on 8443; Databricks JDBC driver in `openidm/lib/`, clean load
- [x] ADR-001 (connector selection criteria, cited)

Databricks tenant connectivity (infrastructure, not spike work):
- [x] Free Edition workspace signed up; `secrets/databricks.env`
      created (host, HTTP path, OAuth URL, JDBC URL, workspace ID)
- [x] Generate PAT → `DATABRICKS_PAT` in `secrets/databricks.env`
      (BI Tools scope preset, 30d). First stored token was already
      expired/revoked (403); fresh mint 2026-09-09 → auth green
- [x] Connectivity smoke test from the lab: `databricks/smoke-test.sh` →
      SMOKE-OK (catalog `workspace`, authed as the workspace user). Env finding in
      spike-results.md: quote the JDBC URL in the sourced env file
      (unquoted `;` truncates it)

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

Client mode is the target and server mode was only a stepping stone
(why: [design.md → Topology](design.md#topology)).

Steps run in order; each must pass the unchanged acceptance suite before
the next adds a layer, so a failure can only come from the layer just
introduced. Earlier steps stay runnable. Research, open questions and validation detail:
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
- [x] `rcs/` tooling (tracked, our own files): `conf/server/ConnectorServer.properties`,
      `deploy.sh`, `run.sh`; `idm-config/deploy.sh rcs` points IDM's
      provisioner at the RCS (`connectorHostRef`, RCS-side `scriptRoots`)
- [x] Proven remote: with IDM's scriptedsql + driver jars removed, IDM lists
      only the RCS connector, connector test ok, 16/16; scripts and the M2M
      customizer execute in the RCS
- [x] `PROFILE=rcs` → **16/16**; switching back (`deploy.sh local`) → T0 16/16

RCS on the Mac, client mode (T2) — working ✅ 2026-09-29:
- [x] `rcs/deploy.sh client` + `rcs/run.sh`: RCS connects to
      `wss://localhost:8443/openicf`; IDM's certificate imported into the RCS
      truststore (which keeps its public CAs for Databricks)
- [x] `idm-config/deploy.sh rcs-client`: IDM `remoteConnectorClients`, provisioner
      pointed at `rcslocal`
- [x] Least-privilege login: RCS authenticates as `connector-server-client`
      (a STATIC_USER login, only role `internal/role/rcs-rcslocal`) and an
      `openicf` access rule admits only that role for `rcslocal`; confirmed in
      IDM's authentication audit
- [x] `PROFILE=rcs-client` → **16/16**
- [ ] Negatives: wrong credentials / admin refused, RCS kill/recovery,
      script-edit reload; token-boundary soak through the RCS

Connector hardening (any topology; design.md → "Sync / change detection"):
- [ ] `SyncScript`: fail loudly on a recreated table (weakness 1 in design.md)
- [ ] `SyncScript`: resume at `token`, skip applied rows (weakness 2 in design.md)

Kubernetes — one pod in minikube, client mode (T3) — working ✅ 2026-09-29:
- [x] `vfkit` installed; stale docker-driver profile deleted; cluster `rcs`
      (minikube 1.38, vfkit, containerd 2.2.1, Kubernetes 1.35.0)
- [x] `rcs/k8s/Dockerfile`: `FROM gcr.io/forgerock-io/rcs:1.5.20.36`, COPY-only
      (driver, scripts, our properties + logback, truststore); built in the
      node by `rcs/k8s/build.sh`; StatefulSet written from scratch
      (`rcs/k8s/manifests/rcs.yaml`), deployed by `rcs/k8s/deploy.sh`
- [x] IDM credentials as a Secret holding a JDK @argfile (not env, not in
      the process list); `idm-config/deploy.sh rcs-k8s` (script path in the pod)
- [x] IDM lab certificate with SAN `localhost` + `host.minikube.internal`
      (`idm-config/lab-tls-cert.sh`) — the shipped CN-only cert failed the
      pod's TLS handshake
- [x] Own `logback.xml`: connector/Groovy output in `kubectl logs`
- [x] `PROFILE=k8s` → **16/16**

Kubernetes — high availability (T3, 2 replicas):
- [x] StatefulSet, Secrets as files, probes, PodDisruptionBudget, IDM
      failover group (`rcsdatabricks`: `rcs0`, `rcs1`, one shared login) —
      **16/16** with 2 pods, 2026-09-30
- [x] Pod kill, first pass (`rcs/k8s/failover-test.sh`): failover detected in
      ~1 s; token consistent on an interrupted liveSync
- [x] Record the decision → [ADR-003](adr-003-rcs-per-external-system.md)
      (one RCS cluster per external system); StatefulSet, naming and
      failover stay in design.md
- [x] Align the lab with the per-system layout and Ping's recommendations:
      `databricks0`/`databricks1`/cluster `databricks`; one login and role
      per connector server (incl. `rcslocal`) — **16/16** on both RCS paths,
      2026-09-30

Inbound sync — mapping and schedule ✅ 2026-10-05 (T3; spike-results 2026-10-05):
- [x] `managed/businessRecord`, inbound mapping, liveSync schedule (tracked
      disabled); recon by ID, full recon and liveSync insert/update/delete
      reach the managed objects; suite **16/16** with the mapping in place
- [x] Scheduled liveSync every 5 s under 5 rounds of 10–30 updates: every
      commit applied, managed objects matched 2–4 s after the last commit
- [x] Mapping reshaped 2026-10-06: `record_id` authoritative in IDM, only
      `ref_id` synced; unknown IDs ignored; a deleted row clears `ref_id`
      and keeps the record — every case verified through liveSync and a
      full recon, suite **16/16**
- [x] Full-recon baseline 2026-10-06, 100,000 Databricks rows vs 6,666
      business records (15:1): 27 s with source paging, ~6 records/s
      without it
- [ ] Tune the recon page size (10,000 so far)
- [ ] Poll interval for real use (vs warehouse auto-stop and cost)
- [ ] Outbound mapping (`managed/outboundRecord` → Databricks, implicit sync)

Known concerns — recorded, not blocking; revisit before the tenant step
(detail: research doc, Unknowns #14, #15):
- [ ] A fresh RCS pod can't reach Databricks until IDM's connector test runs
      on it — hits every pod restart and every failover
- [ ] Requests lost between IDM and the RCS pods stall up to IDM's 900 s
      group check — seen with a pod kill and, without one, while the Mac
      slept; rechecked awake 2026-10-05: a liveSync across a pod kill still
      fails

## History table (SCD Type 2) — proof

Test what the sync engine does with a history table, where the object's
key repeats across versions, against the expected ranking in
[databricks-requirements.md → Table shape](databricks-requirements.md#table-shape).
Any topology; existing object classes unchanged.

- [ ] `databricks/sql/002_history_table.sql`: `access_grant_history` (BIGINT
      key repeating per version, STRING reference, `valid_from`, `valid_to`
      with a sentinel for open versions, `is_active`; all NOT NULL; CDF on),
      plus a Type 1 current-state table of the same objects for comparison
- [ ] Dummy data, one commit per scenario: open an object; close a version
      and open the next in one commit; end an object with no successor; a
      backdated version; a future-dated version; two active rows for one key
- [ ] Probe: uncollapsed rows (duplicate source IDs) through recon and
      liveSync — record what IDM does
- [ ] Object class `accessGrant` (uid = the BIGINT, latest version per key):
      Schema, Search and Sync scripts
- [ ] Run each scenario through liveSync and recon; time recon against the
      history table vs the current-state table as history grows
- [ ] Record results in spike-results.md; correct Table shape if they
      contradict it

## Phase 3 — real AIC tenant

- [ ] Tenant access (dev env); one RCS OAuth client per connector server
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
- [ ] Register connector servers, cluster, and an OAuth client + role per
      server in AIC (README → Runbook →
      "AIC: one RCS cluster per system");
      `PROFILE=tenant` → 16/16
- [ ] Websocket idle survival through the provider's egress (soak)
- [ ] Ask Ping: redistribution terms for a derived RCS image
