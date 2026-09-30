# Design — Databricks ⇄ PingAIC bidirectional connector

Describes the current design; claims are tagged [documented],
[verified] or [to test]. Build status: [plan.md](plan.md). Decisions cite [ADR-001](adr-001-connector-selection.md);
research backing the target is in [rcs-kubernetes-research.md](rcs-kubernetes-research.md).

## Components

| Component | Role | Phase-1 realization |
|---|---|---|
| Databricks | System of record (inbound) / target (outbound) | Free Edition, serverless SQL warehouse, Unity Catalog, Delta tables |
| ICF connector | CRUD + sync over JDBC | **ScriptedSQL (Groovy)** — decided per ADR-001 (auth posture + topology); bundled in PingIDM |
| JDBC driver | Wire protocol | OSS `databricks-jdbc`, class `com.databricks.client.jdbc.Driver` (verified from jar), in `openidm/lib/` |
| Sync engine | Recon, liveSync, mappings | Local PingIDM (DS-backed) standing in for AIC — same engine, configs port to tenant |
| RCS | Connector host in production topology | Client mode — see Topology |

Ping ships no Databricks connector and documents no Databricks integration
(checked 2026-09-30 in the [ICF connector list](https://docs.pingidentity.com/openicf/connector-reference/preface.html)
and Ping's docs). The nearest, the
[Snowflake connector](https://docs.pingidentity.com/openicf/connector-reference/snowflake.html),
manages users and roles, not table data. This design rests on Ping's generic
ScriptedSQL docs and Databricks' own JDBC and change-feed docs.

### Connector vs RCS

Two different things that are easy to conflate — and they scale differently.

| | ICF connector (ScriptedSQL + our Groovy scripts) | Remote Connector Server (RCS) |
|---|---|---|
| What it is | Code that speaks one system's protocol (here JDBC/SQL to Databricks) | A Java server process that *hosts* connectors |
| Runs where | Inside a host: IDM itself (phase 1) or an RCS (phase 2+) | Customer-side network: a VM or a Kubernetes pod |
| Knows about | Target schema, queries, target credentials (delivered at runtime) | How to reach IDM/AIC and load connector bundles |
| State | Per-host connector instances + JDBC pool; no durable state | None — mappings, schedules, sync token and connector config all live in IDM/AIC |
| Changed by | Schema/query/script changes; provisioner JSON (in IDM/AIC) | Network, availability, upgrades, image rebuilds |
| Scales | **Up, inside each host** — pool size, pod CPU/memory | **Out, for availability** — more RCS instances, each separately named, grouped in a cluster |

Consequences:
- An RCS *can* host many connectors, but this design gives each external
  system its own RCS cluster ([ADR-003](adr-003-rcs-per-external-system.md)).
- Every RCS instance opens its **own** JDBC pool: Databricks connections ≈
  RCS instances × pool size. The warehouse, not RCS count, bounds throughput.
- Adding RCS instances adds no sync capacity: liveSync/recon schedules and
  the CDF sync token live in IDM/AIC.
- In client mode (the only mode AIC supports) RCS dials **out** over
  websocket/443 and holds no inbound port.

## Data model (lab; real names swap in later)

Both tables: an ID, a second ID, a datetime stamp. Delta, Unity Catalog.

- **Inbound source:** `<catalog>.idm_lab.business_records`
  `record_id STRING` (key), `ref_id STRING`, `last_modified TIMESTAMP`
  Change Data Feed enabled — the sync path (see Sync / change detection).
- **Outbound target:** `<catalog>.idm_lab.outbound_records`
  same shape, disjoint data.

Column type is `TIMESTAMP` (not `TIMESTAMP_NTZ`); timestamp interchange format
is `yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` — UTC, full microseconds (Databricks
TIMESTAMP precision), fixed width so lexicographic order = chronological.

## IDM object model and mappings

Bidirectional = two unidirectional mappings over disjoint datasets (no loop risk):

| | Inbound | Outbound |
|---|---|---|
| System object | `system/databricks/businessRecord` | `system/databricks/outboundRecord` |
| Managed object | `managed/businessRecord` (target) | `managed/outboundRecord` (source) |
| Mapping | recon + liveSync (CDF sync token) | implicit sync on managed-object change + recon |

**Provisioner naming convention:** a provisioner is named for the *system* it
connects to — never for a flow direction, which belongs to mappings. With
ScriptedSQL decided (ADR-001), a single `provisioner.openicf-databricks.json`
serves both directions: one connector instance, two object classes named for
their datasets.

## Read-only attribute set (inbound)

Attribute list TBD (business decision). Enforcement is two-layer:
- Connector level: declared `NOT_UPDATEABLE`/`NOT_CREATABLE` in
  `SchemaScript.groovy` (flags verified in the shipped framework jar).
- Mapping level: attributes absorbed source→managed only; never mapped
  managed→source.

## Sync / change detection

Sync token = Delta Change Data Feed (CDF) `_commit_version` (Long), read by
`SyncScript.groovy`. The `last_modified` column is data only, not the sync
mechanism. What a Databricks team must provide:
[databricks-requirements.md](databricks-requirements.md).

How CDF maps onto ICF sync:

| ICF operation | Statement | Notes |
|---|---|---|
| `GET_LATEST_SYNC_TOKEN` | `DESCRIBE HISTORY <table> LIMIT 1` → `version` | Initial token; liveSync emits nothing until changes arrive (the initial load is recon's job) |
| `SYNC` | `table_changes('<table>', token + 1)` filtered to `insert`, `update_postimage`, `delete`, ordered by `_commit_version, <key>` | Deletes arrive as `delete`; token = highest `_commit_version` processed, one per object class/table |

Why CDF rather than a timestamp column (ADR-001, supporting reason):
deletes are detected; the token is assigned by Delta and strictly ordered,
so there are no clock, tie or precision problems, and no dependence on
writers stamping a column. Costs: CDF must be on per table, only records
changes after it is enabled, and change data lives only as long as the
table's retention (VACUUM deletes it) — an outage longer than that needs a
full recon.

The SQL warehouse is only the compute that runs these statements; CDF is a
property of the Delta table. Warehouse behaviour affects operations, not
the strategy: auto-stop vs poll interval (cost and cold starts), and sync
pauses — without losing changes — while the warehouse is unavailable.

**Where CDF isn't available** (views, federated tables, non-Delta files, or
a subset spread across an analytics model), in order of preference:
1. A small **sync table** the data team maintains (Delta, CDF on) holding
   just the needed subset.
2. CDF straight from the source table, selecting only needed columns —
   workable when the subset comes from one table.
3. A **view + timestamp column** watermark: creates/updates only, deletes
   via periodic full recon; needs every write to stamp it (from the
   database clock), a timestamp spanning all joined sources, a safety lag
   for in-flight writes, and tie handling. Would need a second sync script.
4. **Full recon only**, for small subsets.

Writes (outbound) go to a Delta landing table the data team merges from —
what they must provide: [databricks-requirements.md → Tables](databricks-requirements.md#tables).

Known `SyncScript` weaknesses (fixes tracked in plan.md):
1. If the table is recreated, versions restart at 0; a stored token above
   the new latest version is reset silently, skipping changes. It should
   fail loudly.
2. Resuming at `token + 1` skips the rest of a commit if a poll fails partway
   through a multi-row commit. Resume at `token` and skip rows already
   applied instead.

## Authentication

Decision and reasons: [ADR-002](adr-002-databricks-authentication.md).

- **Method: service-principal OAuth M2M** everywhere
  (`AuthMech=11;Auth_Flow=1;OAuth2ClientId/Secret` on JDBC; client
  credentials at `/oidc/v1/token` for REST; access tokens valid one hour).
  Lab SP: `idm-connector-lab`. Pool `maxAge` is 50 min so no pooled
  connection outlives its token (driver M2M auto-refresh is undocumented).
- **PAT: optional alternative**, never required. `deploy.sh` keeps none in
  `boot.properties`, so the connector never uses one. The admin tooling
  (`databricks/JdbcRunner.java` behind `apply-sql.sh`/`smoke-test.sh`) and
  the suite's out-of-band checks use the SP when `DATABRICKS_SP_CLIENT_ID`
  + `DATABRICKS_SP_CLIENT_SECRET` are set, and fall back to
  `DATABRICKS_PAT` only when they are not. `JdbcRunner --describe-auth`
  shows which method it would use, redacted.

### Credential path (ScriptedSQL, as built)

The provisioner's `customSensitiveConfiguration` — a GuardedString property,
**encrypted by IDM at rest** — carries
`oauth2 { clientId = '&{databricks.sp.client.id}'; secret = '&{databricks.sp.client.secret}' }`,
substituted from `resolver/boot.properties` (lab; ESVs in AIC), synced from
`secrets/` by `idm-config/deploy.sh`. At connector init the framework decrypts
it into `configuration.propertyBag`, and `CustomizerScript.groovy` strips any
auth params from the base `&{databricks.jdbc.url}` and appends the M2M set —
so the secret exists only in encrypted config and in memory, never in a
plaintext property. `username`/`password` are unused placeholders (the driver
ignores UID/PWD under `AuthMech=11`; verified). Rotation: step 8 below.

**Verified toolkit fact (1.5.20.33):** the scripted-sql customizer is a plain
script body with `configuration` in the binding; the scripted-REST
`customize { init { … } }` DSL breaks script loading here. The ScriptedSQL
doc page omits the customizer/custom-config properties, but
`ScriptedSQLConfiguration` inherits them from `ScriptedConfiguration`
(verified via javap and live probe).

### Setting up OAuth M2M (service principal)

Works on Free Edition (verified 2026-09-09); all steps are done in the lab
for SP `idm-connector-lab` (client ID in `secrets/databricks.env`). Repeat
per workspace (e.g. the tenant's).

1. **Create the service principal** (workspace Settings → Identity and
   access → Service principals; or the workspace SCIM API). ✔ lab
2. **Generate an OAuth secret** for it (SP → Secrets → Generate secret) —
   record client ID + secret once. ✔ lab
3. **Least-privilege grants** per
   [databricks-requirements.md → Access](databricks-requirements.md#access)
   (lab: the two lab tables only). ✔ lab (verified: `SELECT current_user()`
   over JDBC returns the SP)
4. **Store the secret out of config:** lab → `secrets/databricks.env` +
   `boot.properties` substitution into the encrypted
   `customSensitiveConfiguration`; AIC → ESVs referenced by the provisioner
   config in the tenant (resolved there, sent to the RCS over `wss`).
   ✔ lab
5. **Customizer assembles the auth:** `CustomizerScript.groovy` appends
   `AuthMech=11;Auth_Flow=1;OAuth2ClientId/OAuth2Secret` at init, replacing
   any auth params in the base URL. ✔ lab — acceptance as the SP,
   confirmed by Databricks query history
6. **Validate token refresh over a held-open pool** (pool `maxAge`, see
   Authentication above). ✔ lab —
   soak 9/9 over 80 min across the token boundary
   (`databricks/soak-test.sh`).
   Note: after an IDM restart against a cold serverless
   warehouse, the first M2M connect (token exchange + warehouse wake) can
   make early operations fail transiently (routes return 404) until the
   pool establishes — self-heals; the acceptance suite's readiness gate
   waits it out. Consider warm-up/retry in production.
7. **No PAT in IDM:** `deploy.sh` removes `databricks.pat` from
   `boot.properties` if present. ✔ lab
8. **Rotation thereafter:** rotate the OAuth secret at the source (new
   secret → update ESV/env → recycle connector); connector config untouched.

## Topology

The lab deliberately keeps **two parallel ways to run the same connector** —
plain JVM and Kubernetes — so their development experience can be compared
hands-on (logged in [k8s-dev-experience.md](k8s-dev-experience.md)). Neither
replaces the other; the same acceptance suite runs against every topology,
one test profile each.

| Topology | Connector host | Connection | Test profile | Status |
|---|---|---|---|---|
| T0 | In-process in local IDM | — | `lab` | as-built (phase 1) |
| T1 | Java RCS on the host JVM | IDM → RCS (server mode, :8759) | `rcs` | as-built stepping stone only — no production use (AIC is client-mode only) |
| T2 | Java RCS on the host JVM | RCS → IDM `wss://…/openicf` (client mode) | `rcs-client` | as-built (least-privilege login) |
| T3 | RCS pods in local Kubernetes (minikube) | RCS → IDM (client mode) | `k8s` | as-built, 2 pods in a failover group |
| T4 | RCS pods in a managed Kubernetes cluster | RCS → AIC tenant (client mode) | `tenant` | target (phase 3) |

Moving between topologies changes only: the provisioner's
`connectorRef.connectorHostRef` and `scriptRoots` (scripts live on the RCS
filesystem, so `&{idm.instance.dir}` no longer applies), a new
`provisioner.openicf.connectorinfoprovider.json`, and where secrets resolve
(`boot.properties` locally, ESVs in AIC). Mappings are untouched.

### High availability: Kubernetes and RCS do different jobs

| Job | Layer | Mechanism |
|---|---|---|
| Keep RCS processes alive | Kubernetes | restart crashed pods, reschedule off failed/drained nodes, hold replica count, spread across nodes/zones |
| Route each operation to a live RCS; fail over | RCS / AIC | Server Cluster in AIC (`remoteConnectorClientsGroups` in IDM 8.1.1), `failover` or `roundrobin` [documented; key name verified] |

They overlap only on "redundancy". A client-mode RCS connects **outbound**,
so no Kubernetes Service sits in the traffic path and Kubernetes cannot
reroute an operation away from a dead pod — only the RCS cluster can.
Kubernetes alone = a 30–90 s outage per restart; RCS cluster alone = no
self-healing. The target uses both.

```
IDM / AIC tenant
 └─ connector-server cluster "databricks" (algorithm: failover)
      ├─ "databricks0" ◄──wss──┐
      └─ "databricks1" ◄──wss──┤   outbound 443 only
                               │
Kubernetes: StatefulSet "databricks", replicas: 2
 ├─ pod databricks-0 → RCS name databricks0 → connector + JDBC pool ──► Databricks
 └─ pod databricks-1 → RCS name databricks1 → connector + JDBC pool ──► Databricks
```

Kubernetes decisions:
- **StatefulSet**, one stable pod name per registered RCS name — HA via
  distinctly named members of a cluster is the documented model
  [documented]; same-name replicas are undocumented and not used.
- **`failover`**, not `roundrobin`, so paged recon doesn't split across
  pods [inference; failover verified 2026-09-30].
- **Fixed replica count, no autoscaling** — each member needs a registration
  and access rule in AIC.
- **Spread + PodDisruptionBudget** so node drains/upgrades never take both.
- **JDBC pool sized per pod** against total Databricks connections.
- **Immutable image**: `FROM gcr.io/forgerock-io/rcs:<pinned>` + driver jar,
  Groovy scripts, our own `ConnectorServer.properties` and `logback.xml`.
  Connector config stays in IDM/AIC and needs no redeploy.
- **Secrets**: the only RCS-side secret is its own credential (server key or
  OAuth client secret) — RCS reads no env vars or placeholders [verified in
  image], so it arrives as `-D` options in a JDK @argfile mounted from a
  Kubernetes Secret and referenced by `OPENICF_OPTS`, which keeps it out of
  the process list [verified]. The Databricks secret stays in
  IDM/AIC and reaches the connector in its configuration, which is why
  TLS/`wss` is mandatory [documented: GuardedString is only default-key
  encrypted in transit].
- **Probes**: RCS has no health endpoint and no shutdown hook [verified in
  image]; startup/readiness/liveness check for an ESTABLISHED socket to the
  upstream port [verified 2026-09-30].

### One RCS cluster per external system

Every external system — and every separate instance of the same kind —
gets its own RCS cluster, with its own image and registered names
(decision and reasons: [ADR-003](adr-003-rcs-per-external-system.md)).
Within a cluster, each connector server
(each pod) has its own OAuth client and its own role, as Ping recommends
[documented: RCS configuration migration FAQ], so a leaked or reset
credential affects one pod, not the cluster. A connector reaches its
cluster only through its `connectorHostRef`.

Names are the system's name, without an `rcs` prefix — they are already
listed as connector servers and clusters. Use lowercase letters and digits
only: the AIC console also accepts `_` and `-`, but the RCS documentation
requires `^[a-z0-9]*$` [documented], and the stricter rule satisfies both.

| Item | Name | Example (`<system>` = `databricks`) |
|---|---|---|
| Connector servers (one per pod) | `<system>0`, `<system>1` | `databricks0`, `databricks1` |
| Server cluster | `<system>` | `databricks` |
| Kubernetes StatefulSet | `<system>` → pods `<system>-0`, `<system>-1` | `databricks-0` → `databricks0` |
| OAuth client (one per connector server) | `<system>0-client`, `<system>1-client` | `databricks0-client` |
| Role (one per connector server) | `<system>0-client-authorized`, … | `databricks0-client-authorized` |

Client and role names follow Ping's own examples (`myrcs1-client`,
`myrcs1-client-authorized`; the built-in `RCSClient` maps to
`rcsclient-authorized`). The connector and its cluster can share one name
(verified 2026-09-30: both `databricks`).

In the lab, both pods mount one Secret holding every server's credentials
file and each loads only its own; a StatefulSet can't give pods different
Secrets. Full per-pod credential isolation would need one StatefulSet per
server, or a secret store that scopes access per pod.

Setting one up in AIC: [README → Runbook → AIC: one RCS cluster per
system](../README.md#aic-one-rcs-cluster-per-system).

### Cloud-provider neutrality

The target is any managed Kubernetes. Everything cloud-specific enters
through a standard Kubernetes interface, so providers differ only by a small
overlay (secret-store binding and a ServiceAccount annotation):

| Capability | Portable layer | Azure | AWS | Google Cloud |
|---|---|---|---|---|
| Managed cluster | Kubernetes API | AKS | EKS | GKE |
| Private image registry | any pull-able OCI registry | ACR | ECR | Artifact Registry |
| Pod identity | ServiceAccount + federated token | Workload Identity | EKS Pod Identity / IRSA | Workload Identity Federation |
| Secret delivery | Secrets Store CSI driver or External Secrets Operator | Key Vault | Secrets Manager | Secret Manager |
| Egress to AIC + Databricks (443) | NetworkPolicy (FQDN rules need Cilium or a firewall) | NAT Gateway / LB outbound | NAT Gateway | Cloud NAT |
| Egress idle timeout ([sources](rcs-kubernetes-research.md#sources)) | RCS websocket ping every 60 s (keep it on) | NAT GW 4 min default; AKS LB outbound 30 min | NAT GW 350 s, fixed (then RST) | Cloud NAT 1200 s default, configurable |
| amd64 image build | multi-arch `buildx` | ACR Tasks | CodeBuild | Cloud Build |

Locally (T3), plain Kubernetes Secrets are mounted at the same path a CSI
volume would use, so the pod is identical across providers. Kubernetes
version: pin a minor supported by the target provider (lab versions:
[README → What you need](../README.md#what-you-need)).
