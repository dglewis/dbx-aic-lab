/*
 * Databricks ScriptedSQL connector — TEST operation.
 * Fails (throws) if the pooled JDBC connection cannot run a trivial query,
 * which prevents the connector from being enabled.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log

log.info("Entering {0} Script", operation)

def sql = new Sql(connection as Connection)
sql.execute("SELECT 1")
