/*
 * Databricks ScriptedSQL connector — SYNC / GET_LATEST_SYNC_TOKEN.
 *
 * Sync token = Delta commit version (Long). Changes come from Change Data
 * Feed via table_changes(<table>, <startVersion>); startVersion is inclusive,
 * so we resume at token + 1. Deletes ARE detected (_change_type = 'delete') —
 * the capability the changelog-column approach lacks (ADR-001).
 *
 * table_changes() arguments cannot be prepared-statement parameters, so the
 * statement is built as a plain String; the version is a Long from the
 * framework and record values never enter the SQL text.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log
import org.identityconnectors.framework.common.exceptions.ConnectorException
import org.identityconnectors.framework.common.objects.ObjectClass

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def objectClass = objectClass as ObjectClass

log.info("Entering {0} Script for {1}", operation, objectClass)

def TABLES = [
        businessRecord: 'workspace.idm_lab.business_records',
        outboundRecord: 'workspace.idm_lab.outbound_records'
]
def table = TABLES[objectClass.objectClassValue]
if (table == null) {
    throw new UnsupportedOperationException(operation.name() + " is not supported for object class " + objectClass.objectClassValue)
}

def TS_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'").withZone(ZoneOffset.UTC)
def formatTs = { ts -> ts == null ? null : TS_FORMAT.format(((java.sql.Timestamp) ts).toInstant()) }

def sql = new Sql(connection as Connection)

// Latest Delta commit version for the table (row 1 of DESCRIBE HISTORY)
def latestVersion = {
    def row = sql.firstRow("DESCRIBE HISTORY " + table + " LIMIT 1")
    return (row.version as Long)
}

switch (operation) {
    case OperationType.GET_LATEST_SYNC_TOKEN:
        def latest = latestVersion()
        log.ok("Latest sync token for {0} is {1}", table, latest)
        return latest

    case OperationType.SYNC:
        def token = token as Object
        def latest = latestVersion()
        // No stored token: start from the current version, emitting nothing —
        // the initial full load belongs to recon, not liveSync.
        def start = (token == null ? latest : (token as Long)) + 1
        if (start > latest) {
            log.ok("No changes for {0}: token {1}, latest {2}", table, token, latest)
            return latest
        }

        def statement = "SELECT record_id, ref_id, last_modified, _change_type, _commit_version " +
                "FROM table_changes('" + table + "', " + start + ") " +
                "WHERE _change_type IN ('insert', 'update_postimage', 'delete') " +
                "ORDER BY _commit_version, record_id"

        sql.eachRow(statement, { row ->
            def version = row['_commit_version'] as Long
            if (row['_change_type'] == 'delete') {
                handler({
                    syncToken version
                    DELETE()
                    object {
                        uid row.record_id
                        id row.record_id
                    }
                })
            } else {
                handler({
                    syncToken version
                    CREATE_OR_UPDATE()
                    object {
                        uid row.record_id
                        id row.record_id
                        attribute 'record_id', row.record_id
                        attribute 'ref_id', row.ref_id
                        attribute 'last_modified', formatTs(row.last_modified)
                    }
                })
            }
        })
        break

    default:
        throw new ConnectorException("SyncScript can not handle operation: " + operation.name())
}
