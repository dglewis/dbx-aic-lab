# Notices

This repository contains **no Ping Identity software or source code**.

- The PingIDM and PingDS distributions (`IDM-8.1.1.zip`, `DS-8.1.1.zip`) are
  proprietary Ping Identity products. They are **not included** here (see
  `.gitignore`), are not redistributable, and must be downloaded from the
  [Ping Identity Backstage](https://backstage.forgerock.com/downloads) site
  under your own license/account.
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
  "Databricks" are trademarks of their respective owners. This is an
  independent lab/prototype, not affiliated with or endorsed by either
  vendor.
