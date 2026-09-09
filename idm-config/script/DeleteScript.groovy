/*
 * Databricks ScriptedSQL connector — DELETE operation.
 * Throws UnknownUidException when nothing was deleted so recon sees the truth.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log
import org.identityconnectors.framework.common.exceptions.UnknownUidException
import org.identityconnectors.framework.common.objects.ObjectClass
import org.identityconnectors.framework.common.objects.Uid

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def uid = uid as Uid
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

def sql = new Sql(connection as Connection)
def deleted = sql.executeUpdate("DELETE FROM " + table + " WHERE record_id = ?", [uid.uidValue])
if (deleted == 0) {
    throw new UnknownUidException("No such record: " + uid.uidValue)
}
