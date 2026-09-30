# Notices

This repository contains **no Ping Identity software or source code**.

- The PingIDM and PingDS distributions (`IDM-8.1.1.zip`, `DS-8.1.1.zip`) are
  proprietary Ping Identity products. They are **not included** here (see
  `.gitignore`), are not redistributable, and must be downloaded from the
  [Ping Identity Backstage](https://backstage.forgerock.com/downloads) site
  under your own license/account.
- The **Java Remote Connector Server (RCS)** — the Backstage zip and the
  official image `gcr.io/forgerock-io/rcs` — is Ping Identity software. The
  image is publicly pullable, but its start scripts and logging config carry
  "Use of this code requires a commercial software license with Ping
  Identity Corporation" (framework jars are CDDL-1.0). Nothing from it is
  included here: `rcs/openicf/` is gitignored, and any Dockerfile in this
  repo only references the image (`FROM …`) and copies this repo's own
  files. Running it requires your own Ping license. Our
  `ConnectorServer.properties`, `logback.xml`, entrypoint and Kubernetes
  manifests are written from the public documentation, not adapted from the
  image's files. Ping has no published statement on redistributing an image
  built on theirs, so this repo publishes none: keep images you build in a
  private registry.
- [ForgeOps](https://github.com/ForgeRock/forgeops) (CDDL-1.0, Ping Identity,
  "as-is" support) was read as a reference for RCS on Kubernetes. No ForgeOps
  files are copied into this repository.
- The Groovy scripts under `idm-config/script/` are original work written
  against the publicly documented
  [Groovy Connector Toolkit](https://docs.pingidentity.com/openicf/connector-reference/groovy.html)
  and
  [Scripted SQL connector](https://docs.pingidentity.com/openicf/connector-reference/scripted-sql.html)
  APIs. They import Ping/ICF framework classes at runtime (as any connector
  script must) but include no vendor sample code.
- The Databricks JDBC driver is fetched from Maven Central
  (`com.databricks:databricks-jdbc`, Apache-2.0 per its POM) and is not
  committed to this repository.
- "Ping Identity", "PingIDM", "PingOne Advanced Identity Cloud", and
  "Databricks" are trademarks of their respective owners, as are
  "Kubernetes", "Azure", "AWS" and "Google Cloud". This is an independent
  lab/prototype, not affiliated with or endorsed by any of these vendors.
