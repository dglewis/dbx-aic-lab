# RCS image for this lab: the official Ping RCS image plus this repo's own
# files. Nothing from Ping is copied into the repo; the base is referenced.
# COPY-only (no RUN), so it builds for any architecture without emulation.
# Build context is staged by rcs/k8s/build.sh.
FROM gcr.io/forgerock-io/rcs:1.5.20.36

# Databricks JDBC driver (Apache-2.0) next to the connector's tomcat-jdbc.
COPY --chown=11111:0 databricks-jdbc-2.7.3.jar /opt/openicf/lib/
# Connector scripts; the provisioner's scriptRoots points here.
COPY --chown=11111:0 scripts/ /opt/openicf/scripts/databricks/
# Client-mode properties and stdout logging (both written for this repo).
COPY --chown=11111:0 ConnectorServer.properties logback.xml /opt/openicf/conf/
# The image's truststore plus the lab IDM certificate (lab only — a real
# tenant's certificate chains to a public CA already in the truststore).
COPY --chown=11111:0 truststore /opt/openicf/security/truststore
