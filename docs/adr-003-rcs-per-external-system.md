# ADR-003: One RCS cluster per external system

**Status:** Accepted (2026-09-30).

## Context

The connector runs on a Remote Connector Server (RCS) — on a plain JVM or
in Kubernetes; this decision holds for both. One RCS can host connectors for
many external systems, and several RCS instances can form a cluster for
failover. An AIC deployment typically connects many systems: out-of-the-box
connectors and scripted ones like this Databricks connector.

What Ping's documentation says, and doesn't:

- **Says:** a cluster's members must carry the same software — "Every
  connector associated with a server cluster must have an identical set of
  JAR files and scripts in its /path/to/openicf/lib directory"
  ([Sync identities](https://docs.pingidentity.com/pingoneaic/identities/sync-identities.html)).
  Each RCS has one library directory (`connectorserver.libDir`) and one
  connector directory (`connectorserver.bundleDir`)
  ([Configure a remote connector server](https://docs.pingidentity.com/openicf/connector-reference/configure-server.html)).
- **Says:** clusters exist for availability — "Use a cluster of remote
  servers when you want to set up load balancing or failover among multiple
  resource servers" (Sync identities).
- **Doesn't say** whether different external systems should share an RCS
  or be isolated on separate ones — neither page above addresses it
  (checked 2026-09-30). Sharing is allowed; nothing recommends for or
  against it.

## Decision

**Every external system — and every separate instance of the same kind of
system — gets its own RCS cluster.** No RCS hosts connectors for more than
one external system.

## Reasons

A shared RCS couples unrelated systems through everything an RCS has only
one of:

| Shared | Consequence of sharing |
|---|---|
| Library and connector directories | Every system's drivers and scripts are installed for all — a Databricks RCS would carry, say, an Azure connector's jars. In a cluster, every member must carry all of them (Ping's identical-jars rule). |
| Upgrades | Upgrading one system's driver, script or connector version means redeploying the RCS every other system runs on. |
| Runtime | One JVM: one system's memory use, crash or restart takes down the others. |
| Release cadence | One image or install: a change for system A is a release for system B. |
| Network reach | The RCS must reach every system's network, so its egress grows with each system added. |

None of that buys anything: the systems are unrelated, so isolation costs
no function.

## Alternatives rejected

- **One RCS cluster for all systems** — fewest instances, but every coupling
  above.
- **Group systems that share a network zone and release cycle** (e.g.
  several LDAP directories in one data center) — fewer instances, but still
  couples their jars, upgrades and runtime; rejected in favour of one rule
  with no exceptions to judge.

## Consequences

- More RCS instances, and one set of connector-server registrations and
  logins per system, to create and operate.
- Each system's RCS carries only that system's driver and scripts; it can
  be upgraded, restarted or broken without touching any other system.
- Naming follows the system (`databricks`, `databricks0`, …) — convention
  and setup: [design.md → One RCS cluster per external system](design.md#one-rcs-cluster-per-external-system).
