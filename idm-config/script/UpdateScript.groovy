/*
 * Databricks ScriptedSQL connector — UPDATE operation.
 *
 * ref_id is the one updatable attribute; last_modified is source-managed
 * (set here via current_timestamp(), declared NOT_UPDATEABLE in the schema).
 * record_id is the immutable key — renames are rejected.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log
import org.identityconnectors.framework.common.exceptions.ConnectorException
import org.identityconnectors.framework.common.exceptions.UnknownUidException
import org.identityconnectors.framework.common.objects.Attribute
import org.identityconnectors.framework.common.objects.AttributesAccessor
import org.identityconnectors.framework.common.objects.ObjectClass
import org.identityconnectors.framework.common.objects.Uid

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def updateAttributes = new AttributesAccessor(attributes as Set<Attribute>)
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

switch (operation) {
    case OperationType.UPDATE:
        def newName = updateAttributes.getName()
        if (newName != null && newName.nameValue != uid.uidValue) {
            throw new UnsupportedOperationException("record_id is the immutable key; rename is not supported")
        }
        if (updateAttributes.hasAttribute("ref_id")) {
            def updated = sql.executeUpdate(
                    "UPDATE " + table + " SET ref_id = ?, last_modified = current_timestamp() WHERE record_id = ?",
                    [updateAttributes.findString("ref_id"), uid.uidValue])
            if (updated == 0) {
                throw new UnknownUidException("No such record: " + uid.uidValue)
            }
        }
        return uid.uidValue

    case OperationType.ADD_ATTRIBUTE_VALUES:
    case OperationType.REMOVE_ATTRIBUTE_VALUES:
        throw new UnsupportedOperationException(operation.name() + " is not supported for object class " + objectClass.objectClassValue)

    default:
        throw new ConnectorException("UpdateScript can not handle operation: " + operation.name())
}
