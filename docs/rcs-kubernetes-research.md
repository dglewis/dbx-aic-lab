# Research — Java RCS, then RCS on Kubernetes

Background research, started 2026-09-29. Current design:
[design.md](design.md) ("Connector vs RCS", "Topology"); build status:
[plan.md](plan.md). This file keeps the evidence and the open questions. Step names match plan.md Phase 2; "Tenant" is plan.md Phase 3.

Tags: **[D]** official vendor doc (Ping, Microsoft, AWS, Google Cloud),
**[IMG]** verified by inspecting the official RCS image (layers + bytecode),
**[L]** verified in the local runtime, **[I]** inference — needs a test.

## Why this order

Each layer gets its own green acceptance run before the next is added, so a
failure can only come from the layer just introduced:

| Step | Topology | New variable introduced | Pass criterion |
|---|---|---|---|
| Baseline | Connector in-process in IDM (Phase 1) | — (baseline) | `npm test` 16/16 |
| Server mode (stepping stone) | Java RCS on the Mac, **server mode** (IDM → RCS :8759) | remote hosting: scripts, driver, secret transport | 16/16 unchanged, connector proven to run on RCS |
| Client mode, Mac | Java RCS on the Mac, **client mode** (RCS → IDM `wss://…/openicf`) | connection direction + auth as AIC uses it | 16/16 |
| Kubernetes, one pod | Official RCS **container image** under minikube, one pod | image, file layout, env/`-D` secrets, logging | 16/16 |
| Kubernetes, HA | Kubernetes contract: Secrets, probes, pod kill, failover group | orchestration | 16/16 + reconnect/failover timings |
| Tenant | Managed Kubernetes dev cluster (client's cloud) → AIC tenant (Phase 3) | cloud egress, secret store, workload identity, ESVs | 16/16 with `PROFILE=tenant` |

Client mode is the target: AIC accepts **only** client mode — "server mode
isn't compatible with PingOne Advanced Identity Cloud" [D configure-server].
The server-mode row was run once as a stepping stone (it proved remote
hosting works) and has no production use for this project.


## Java RCS — facts that shape the RCS-on-Mac steps

**Version / JDK.** Why 1.5.20.36: latest at the time; fixes a hung token
refresh that blocked websocket upgrades, adds shared token cache,
hostId-routed paged recon [D release notes]. Supported JDKs for ≥1.5.20.32:
17 or 21; 25 is not listed [D java-server]. Pinned versions: README → What
you need. IDM 8.x is compatible with RCS 1.5.x [D
before-you-install]. Our provisioner range `[1.5.0.0,1.6.0.0)` covers it.

**Getting it.** Zip from Backstage (account required) [D]. Also a public-pull
official image `gcr.io/forgerock-io/rcs:1.5.20.36` [D rcs-docker, IMG].
Either way use is under Ping's commercial license; no official statement on
redistributing a derived image [IMG] — consequence: NOTICE.md.

**What ships.** The image (and presumably the zip) already contains
`connectors/scriptedsql-connector-1.5.20.36.jar` with Groovy 3.0.25 [IMG]
(IDM local copy: 1.5.20.33 / Groovy 3.0.22 [L]). We add only
`databricks-jdbc-3.4.3.jar` → `openicf/lib/` ("Third-party libraries for
remote connectors belong in `openicf/lib/`" [D remote-connector]) and the
Groovy scripts.

**Layout.** `openicf/{bin,conf,connectors,lib,scripts,security,logs,tmp}`.
Start: `bin/ConnectorServer.sh /run`; set server key: `/setKey <key>`;
default port 8759 [D java-server].

**Config precedence.** RCS reads `conf/ConnectorServer.properties`, and any
JVM `-D` property overrides the file. There is **no** env-var or `&{}`
substitution in RCS [IMG bytecode]. Secrets go in `OPENICF_OPTS="-D…"` [D
configure-server].

**Key properties** [D configure-server]:
- Server mode: `connectorserver.port`, `connectorserver.usessl` (lowercase —
  the code key is case-sensitive [IMG]), `connectorserver.key` (hash set by
  `/setKey`), `pingPongInterval=60`, keystore/truststore props (PKCS12 since
  1.5.20.35).
- Client mode: `connectorserver.url` (space-separated in file,
  comma-separated in `OPENICF_OPTS`), `connectorServerName`, `hostId`,
  `tokenEndpoint`, `clientId`, `clientSecret`, `scope`, interval and
  connection properties, `proxy*`. Values to set for AIC: README → Runbook
  → "AIC: one RCS cluster per system".

**IDM side.** New `conf/provisioner.openicf.connectorinfoprovider.json`:
- server mode → `remoteConnectorServers: [{name, host, port, useSSL, key, …}]`
  (IDM 8.1.1 reads `useSSL`, not the docs' `usessl` [L] — Unknowns #1);
- client mode → `remoteConnectorClients` (RCS dials `wss://<idm>:8443/openicf`) [D];
- HA → a group with `algorithm: failover|roundrobin` [D] (server mode:
  `remoteConnectorServersGroup`); IDM 8.1.1 reads
  client-mode groups from the top-level `remoteConnectorClientsGroups`
  (Unknowns #10).
The provisioner gains `connectorRef.connectorHostRef: "<name>"`; `&{}` is
not allowed inside `connectorRef` [D property-substitution]. Websocket is
the only protocol since IDM 7 [D removed-functionality].

**Changes our connector needs** (all [I], confirmed by server-mode step):
1. `scriptRoots` — `&{idm.instance.dir}` is resolved by IDM to an IDM-host
   path; the scripts run on the RCS filesystem. Use an RCS path
   (e.g. `&{rcs.script.root}` → `/opt/openicf/scripts/databricks`). Avoid
   `//` in the path (OPENICF-2974 [D known-issues]).
2. `connectorHostRef` added.
3. Secret transport: IDM resolves `&{databricks.sp.client.*}`, decrypts the
   GuardedString and ships it to RCS encrypted only with the framework's
   *known default key* — Ping recommends SSL "for true encryption" [D
   GuardedString javadoc]. So TLS/`wss` is mandatory once past the first
   smoke run. Upside: **the Databricks secret never needs to live in the
   RCS pod**; the only RCS-side secret is the server key or the RCS OAuth
   client secret.
4. `CustomizerScript.groovy` should run unchanged (`propertyBag` populated
   on the RCS side).

**Diagnostics.** `POST /openidm/system?_action=testConnectorServers` → per
server `ok` [D]; `_action=availableConnectors` lists remote connectors [D];
`/openidm/system/databricks?_action=test`. RCS logs: `ConnectorServer.log`,
`Connector.log` (connector/Groovy output goes **only** here by default, not
stdout [IMG]). AIC UI shows Connected / "Waiting to connect…".

## server/client-mode steps validation sequence (bare JVM)

1. baseline green; note commit + run log.
2. Extract RCS 1.5.20.36 into `rcs/` (untracked contents); JDK 21. Pass:
   `/run` listens on 8759; `connectors/` contains scriptedsql.
3. Driver → `rcs/openicf/lib/`; scripts → `rcs/openicf/scripts/databricks/`;
   `/setKey` from a value in `secrets/`. A `rcs/deploy.sh` analogue of
   `idm-config/deploy.sh` keeps this reproducible.
4. Tracked connectorinfoprovider JSON (`key: "&{rcs.key}"`, `useSSL:false`
   for the first run only), provisioner edits above, `deploy.sh`. Pass:
   `testConnectorServers` ok, `availableConnectors` shows remote scriptedsql.
5. **Prove it runs remotely:** temporarily remove scriptedsql + databricks
   jars from `runtime/openidm` only. Pass: connector test ok; customizer log
   line appears in RCS `Connector.log`, not IDM's; Databricks query history
   shows the SP.
6. `npm test` 16/16 (add a `PROFILE=rcs`; package.json already names it).
7. Negatives: wrong key → `ok:false`; kill RCS → failure, then time recovery
   after restart; edit a script on RCS → record whether it takes effect
   without restart (`recompileGroovySource` default false).
8. TLS on both sides (RCS PKCS12 keystore → IDM truststore). Pass: 16/16;
   capture on 8759 shows no plaintext secret.
9. Token-boundary soak through RCS (as Phase 1, 80 min).
10. **client-mode step:** switch to client mode against local IDM (`remoteConnectorClients`,
    RCS dials `wss://localhost:8443/openicf`), repeat 6–7.

## RCS on Kubernetes — facts that shape the Kubernetes steps

**Official image** `gcr.io/forgerock-io/rcs:1.5.20.36` [D rcs-docker, IMG]:
- First **multi-arch** tag (amd64 + arm64) — native on Apple Silicon, same
  tag on amd64 cloud nodes. No `latest` tag; pin by digest.
- `debian:bookworm-slim` + jlinked Zulu 21; user `11111`; workdir
  `/opt/openicf`; Java is PID 1 via `exec`.
- Env: `JAVA_OPTS` (default `-XX:MaxRAMPercentage=80`), `OPENICF_OPTS`
  (expanded **unquoted** — secrets with spaces or `*?[` break; generate
  secrets from a safe charset), `LOGGING_CONFIG`, `OPENICF_TMPDIR`; `jpda`
  arg for remote debug.
- Documented customization: `FROM gcr.io/forgerock-io/rcs:<tag>`, `COPY`
  `conf/ lib/ scripts/`; non-secret props in the file, secrets via
  `OPENICF_OPTS` at runtime. Sample Dockerfile ships in the distribution.
- Default truststore has public CAs incl. Microsoft/DigiCert roots and
  validates Databricks (Unknowns #6). RCS sets `javax.net.ssl.trustStore` to its
  own truststore, so JDK `cacerts` edits don't apply.

**ForgeOps `charts/rcs`** (2026.3, "as-is" support) — useful reference, not
adoptable as-is: StatefulSet, one connector-server name per pod
(`$(hostname)`), hardened securityContext with emptyDir copy of
`/opt/openicf`, egress-only NetworkPolicy. But it uses a different image
(Corretto 26 — outside Ping's Java 17/21 support), invalid
`values-client.yaml`, dead `loggingConfigFile`/`useSSL` properties, no
probes, and jars via ConfigMap (1 MiB cap — the Databricks driver won't fit).

**Topology / HA:**
- Documented HA = several **distinctly named** connector servers in an AIC
  Server Cluster, `failover` or `roundrobin`; all members need identical
  jars/scripts [D sync-identities, rcs-docker]. Same-name replicas are
  **not documented** (a `hostId` property exists). Resolved (naming,
  algorithm): Unknowns #10; decision in design.md.
- Schedules and the CDF sync token live in IDM/AIC; RCS pods are stateless
  (each holds its own JDBC pool).

**Networking.** Client mode: egress only — 443 to the tenant (`/openicf/N`
websockets + AM token endpoint) and DNS; no Service. The websocket ping
(every 60 s by default) is under every major provider's egress idle timeout (values:
design.md → Cloud-provider neutrality) [D MS, D AWS, D GCP]. Never set
`pingPongInterval=0` in a cloud.
Multi-region HA changes tenant IPs — allow egress by FQDN, not IP. The
Databricks JDBC driver needs its own proxy settings if a proxy is used.

**Secrets.** RCS reads only file + `-D` [IMG]. `-D` values set directly in
`OPENICF_OPTS` are visible in `/proc/1/cmdline`; a JDK @argfile avoids that
(as built — design.md → Topology).
Use a **dedicated OAuth client and a separate role per connector server**:
"Ping Identity recommends that you migrate each of these connector servers
to use specific OAuth 2.0 clients" and "create a separate role for each
connector server" [D rcs-migration-faq]. (The sync-identities page only
calls a dedicated client optional; the FAQ is the recommendation.) The
built-in `RCSClient` is shared by every RCS, so resetting its secret
disconnects them all. Databricks secret in AIC →
ESV `&{esv.…}` in the provisioner (encrypted `$crypto` values don't promote
across environments [D]); whether an ESV works *inside* the
`customSensitiveConfiguration` string is untested.

**Health / lifecycle.**
- **No health endpoint.** Client mode opens no port [IMG]; the exec probe
  on an ESTABLISHED upstream socket in `/proc/net/tcp*` works (Unknowns #9).
  Server mode: tcpSocket on 8759.
- **No shutdown hook** — SIGTERM kills the JVM without closing websockets
  gracefully [IMG]. Mitigate with a failover group; measure in Kubernetes HA step.
- Always set a memory limit (`MaxRAMPercentage=80` by default).
- Ship a custom `logback.xml` so connector/Groovy logs reach stdout; mind
  the "redact hosts" rule — RCS logs the tenant URL at startup.
- `readOnlyRootFilesystem` needs emptyDirs for `logs/` and `tmp/`.

**Delivery.** Immutable image per change (driver + scripts + conf baked
in); roll the StatefulSet. Connector config stays in IDM/AIC, so provisioner
changes need no redeploy. For script iteration only: bind-mount `scripts/`
with `recompileGroovySource=true` [D].

## Kubernetes for development — pros and cons

| | Pros | Cons |
|---|---|---|
| Plain JVM (server/client-mode steps) | Seconds per iteration; debugger attaches; isolates RCS behaviour | Tests nothing about the image or orchestration |
| Local K8s (Kubernetes steps) | Tests the real artifact: image, file layout, Secrets-as-files, probes, limits/OOM, pod-kill reconnect, failover groups, manifests/Helm; same API as any managed Kubernetes | 30–90 s per iteration; debugging indirection; a VM (2–4 GB); **cannot** reproduce cloud egress/idle timeouts, the cloud secret store, workload identity, private-registry pull, the provider's CNI |
| Managed Kubernetes dev cluster (tenant step) | The only honest test of the cloud-specific pieces | Cost; slower loop |

Verdict: Kubernetes is overkill as the daily loop for connector logic; it
earns its place as a few rehearsals of the deployment contract. Keep
connector/script work on the plain JVM and treat local K8s as a
gate, not a workspace. Cloud-specific behaviour is deferred to a
short-lived managed-Kubernetes dev cluster on the client's cloud.

## Local Kubernetes on this Mac

State [L]: `kubectl` 1.35, `minikube` 1.38, `helm` 4.1 installed; **no
Docker**, no vfkit/podman/colima; a stale minikube profile (docker driver)
that errors — delete it first.

Recommendation: **minikube + vfkit driver + containerd** (versions: README).
- No Docker needed (Apple Virtualization.framework); Apache-2.0, so no
  Docker Desktop licence question (Docker Desktop is paid for companies
  ≥250 staff or ≥$10M revenue; OrbStack is paid for commercial use).
- containerd matches AKS/EKS/GKE defaults; 1.35 is the newest minikube 1.38
  offers and is AKS-supported until Mar 2027. Match the minor to whatever
  the target provider supports.
- `minikube image build` builds inside the node — no local builder needed.
  The official image is multi-arch, so a COPY-only Dockerfile on top builds
  natively (arm64) locally; production image built amd64 via
  multi-arch `buildx` or the provider's builder (ACR Tasks / CodeBuild /
  Cloud Build) into a private registry.
- Pods reach the Mac via `host.minikube.internal` (IDM must bind 0.0.0.0);
  macOS 15+ needs Local Network permission for the terminal.
- Fallback: Colima + k3s (MIT, Rosetta for amd64 runs). kind/k3d need a
  container runtime this Mac doesn't have.

Setup commands: README → Runbook → Kubernetes path.

## Licensing scan (2026-09-29)

Headers and legal files only — not legal advice. Consequences are in
[NOTICE.md](../NOTICE.md).

| Artifact | Licence found | Consequence for this public repo |
|---|---|---|
| ForgeOps repo (`charts/rcs`, `docker/rcs`) | Repo-level CDDL-1.0, © Ping Identity; no per-file headers | Open source, file-level copyleft. Reference only; our manifests are written clean-room to keep one repo licence |
| RCS image `bin/ConnectorServer.sh`, `bin/openicf.sh`, `conf/logback.xml`, `conf/README.txt` | "Use of this code requires a commercial software license with Ping Identity Corporation" | Proprietary — never copied or adapted; we write our own `logback.xml` |
| RCS image `conf/ConnectorServer.properties` | CDDL header | Copyable with header, but ours is written from the docs |
| RCS image `docker/Dockerfile`, `bin/docker-entrypoint.sh` | No header | Treated as proprietary; our Dockerfile only does `FROM` + `COPY` of our files |
| Connector framework/server jars | CDDL-1.0 (manifests) | Consumed from the image at runtime, never committed |
| Grizzly jars | CDDL + GPL | Same |
| Third-party jars (Groovy, commons, …) | Apache-2.0, BSD-2, EPL-1.0, CDDL (`legal-notices/THIRDPARTYREADME.txt`) | Same |
| `legal-notices/CC-BY-NC-ND.txt` | Ships in the image; scope not determined (likely documentation) | Nothing from it is used |

## Unknowns — each needs an empirical test

| # | Question | Gate |
|---|---|---|
| 1 | `useSSL` vs `usessl` in IDM connectorinfoprovider | server-mode step — **answered**: IDM 8.1.1 uses `useSSL` (from `createConnectorServerCoreConfig`); its IDM-side defaults are housekeeping 600 s, group check 900 s, ping-pong 300 s, not the documented RCS defaults (housekeeping 20, group check 60, ping-pong 60) |
| 2 | CustomizerScript/GuardedString path unchanged on RCS | server-mode step — **answered**: arrives as `GuardedString`, populates `propertyBag.oauth2`, customizer unchanged. One unexplained first-init miss (see spike-results) |
| 3 | scriptedsql 1.5.20.36 + databricks-jdbc 3.4.3 on Java 21 | **works** — 16/16 on every path, no JVM flags (spike-results 2026-10-05) |
| 4 | Script-edit reload behaviour on RCS | Server mode (stepping stone) |
| 5 | Local IDM 8.1.1 accepts client-mode RCS (auth method) | Client mode, Mac — **answered**: basic credentials via a STATIC_USER login (`connector-server-client`) plus an `openicf` access rule; without a rule IDM allows any authenticated user and warns |
| 6 | Default RCS truststore validates the Databricks endpoint | Kubernetes, one pod — **answered**: yes (plus the lab IDM cert added) |
| 7 | Custom logback puts Groovy output on stdout | Kubernetes, one pod — **answered**: yes, via our own `logback.xml` |
| 8 | Pod kill mid-recon/liveSync: IDM error, failover time, sync-token consistency | Kubernetes, HA — **partly answered** (2026-09-30): IDM sees the closed socket in ~1 s and routes to the next member; the stored token did not move on an interrupted liveSync (no skipped rows). Open: #14, #15 |
| 9 | Client-mode liveness probe fidelity (`/proc/net/tcp` vs `testConnectorServers`) | Kubernetes, HA — **answered at socket level**: the ESTABLISHED-socket check passes when connected and fails on a port with no connection; agrees with `testConnectorServers`. A hung-but-connected RCS would still pass (untested) |
| 10 | Same-name replicas vs distinct names + cluster; hyphens in names | Kubernetes HA — **answered**: distinct names per pod (`rcs0`, `rcs1`, from the pod name); names must match `^[a-z0-9]*$` [D configure-server], so no hyphens. The group goes under `remoteConnectorClientsGroups` (plural, top level) in IDM 8.1.1 — the documented placement inside `remoteConnectorClients` was ignored |
| 11 | ESV inside `customSensitiveConfiguration` | Tenant |
| 12 | Websocket idle survival through the provider's egress (NAT/LB) | Tenant |
| 13 | Redistribution terms for a derived RCS image (ask Ping) | before tenant step |
| 14 | A freshly started RCS fails every data operation (JDBC URL without the M2M settings) until IDM's connector **test** action runs on it once; test runs the customizer. By design or a framework defect? Affects every pod restart, not only failover | Known concern — revisit before tenant step (options: scheduled test call as a warm-up; ask Ping) |
| 15 | Requests lost between IDM and the RCS pods: seen as a liveSync that never returned after a pod kill, and (2026-09-30) as a search and a liveSync that stalled with no kill at all. Neither pod received the request; IDM recovered at its next group check (IDM-side default 900 s — #1). Those stalls coincided with the Mac sleeping, which suspends the minikube VM (its clock fell 67 min behind); with sleep blocked, 16/16. Likely environmental in the lab; a request lost to a dead or frozen RCS still waits up to 900 s. Rechecked awake (2026-10-05, driver 3.4.3): a liveSync interrupted by a pod kill still returned nothing; the next one failed (HTTP 500, "Interim message missed"); the same liveSync without a kill was clean — the open point is liveSync across a pod kill | Known concern — before the tenant step, decide whether IDM-side interval settings should be lowered (ask Ping) |
| 16 | Does `SELECT` alone allow `DESCRIBE HISTORY` (the connector's latest-version query)? Databricks documents `SELECT` for `table_changes()` but no privileges for `DESCRIBE HISTORY`; the lab SP also has `MODIFY`, so it was never tested read-only | Before tenant step — test: scratch table with CDF, SP granted only `SELECT` ([table_changes](https://docs.databricks.com/aws/en/sql/language-manual/functions/table_changes), [DESCRIBE HISTORY](https://docs.databricks.com/aws/en/sql/language-manual/delta-describe-history)) |
| 17 | Where a system's cluster members run: spread across network zones (cross-zone failover) or kept in one location (segregation)? Compatible with ADR-003 either way; depends on where the external system and AIC egress sit | Tenant step — decide per system with the client's network layout |

## Sources

Ping: [configure-server](https://docs.pingidentity.com/openicf/connector-reference/configure-server.html) ·
[java-server](https://docs.pingidentity.com/openicf/connector-reference/java-server.html) ·
[rcs-docker](https://docs.pingidentity.com/openicf/connector-reference/rcs-docker.html) ·
[remote-connector](https://docs.pingidentity.com/openicf/connector-reference/remote-connector.html) ·
[example-server](https://docs.pingidentity.com/openicf/connector-reference/example-server.html) ·
[configure-connector](https://docs.pingidentity.com/openicf/connector-reference/configure-connector.html) ·
[systems-over-rest](https://docs.pingidentity.com/openicf/connector-reference/systems-over-rest.html) ·
[scripted-sql](https://docs.pingidentity.com/openicf/connector-reference/scripted-sql.html) ·
[groovy](https://docs.pingidentity.com/openicf/connector-reference/groovy.html) ·
[icf-logs](https://docs.pingidentity.com/openicf/connector-reference/icf-logs.html) ·
[RCS release notes](https://docs.pingidentity.com/openicf/connector-release-notes/connector-server.html) ·
[known issues](https://docs.pingidentity.com/openicf/connector-release-notes/known-issues.html) ·
[GuardedString](https://docs.pingidentity.com/openicf/_attachments/apidocs/org/identityconnectors/common/security/GuardedString.html) ·
[IDM 8.1 before-you-install](https://docs.pingidentity.com/pingidm/8.1/release-notes/before-you-install.html) ·
[IDM 8.1 removed](https://docs.pingidentity.com/pingidm/8.1/release-notes/removed-functionality.html) ·
[IDM 8.1 property substitution](https://docs.pingidentity.com/pingidm/8.1/setup-guide/using-property-substitution.html) ·
[AIC sync identities](https://docs.pingidentity.com/pingoneaic/identities/sync-identities.html) ·
[AIC RCS + AD use case](https://docs.pingidentity.com/pingoneaic/use-cases/use-case-provision-rcs-ad.html) ·
[AIC RCS migration FAQ](https://docs.pingidentity.com/pingoneaic/product-information/migration-dependent-features/rcs-configuration-migration-faq.html) ·
[AIC ESV placeholders](https://docs.pingidentity.com/pingoneaic/tenants/configuration-placeholders-api.html) ·
[ForgeOps support](https://docs.pingidentity.com/forgeops/latest/start/support.html) ·
[ForgeOps charts/rcs](https://github.com/ForgeRock/forgeops/tree/main/charts/rcs)

Microsoft: [AKS versions](https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions) ·
[AKS Standard LB](https://learn.microsoft.com/en-us/azure/aks/configure-load-balancer-standard) ·
[AKS NAT Gateway](https://learn.microsoft.com/en-us/azure/aks/nat-gateway)

AWS: [NAT gateway troubleshooting (350 s idle)](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-troubleshooting.html) ·
Google Cloud: [Tune Cloud NAT (1200 s established TCP)](https://docs.cloud.google.com/nat/docs/tune-nat-configuration)

Local K8s: [minikube drivers](https://minikube.sigs.k8s.io/docs/drivers/) ·
[vfkit](https://minikube.sigs.k8s.io/docs/drivers/vfkit/) ·
[host access](https://minikube.sigs.k8s.io/docs/handbook/host-access/) ·
[Docker pricing FAQ](https://www.docker.com/pricing/faq/) ·
[OrbStack pricing](https://orbstack.dev/pricing) ·
[Colima](https://github.com/abiosoft/colima)
