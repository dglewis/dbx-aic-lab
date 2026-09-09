/*
 * Databricks ScriptedSQL connector — CREATE operation.
 *
 * record_id (__NAME__) is client-supplied and becomes the Uid. Unity Catalog
 * PRIMARY KEY constraints are informational only — Databricks does NOT
 * enforce them — so uniqueness is pre-checked here.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log
import org.identityconnectors.framework.common.exceptions.AlreadyExistsException
import org.identityconnectors.framework.common.exceptions.InvalidAttributeValueException
import org.identityconnectors.framework.common.objects.Attribute
import org.identityconnectors.framework.common.objects.AttributesAccessor
import org.identityconnectors.framework.common.objects.ObjectClass
import org.identityconnectors.framework.common.objects.Uid

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def createAttributes = new AttributesAccessor(attributes as Set<Attribute>)
def recordId = id as String
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
if (recordId == null || recordId.isEmpty()) {
    throw new InvalidAttributeValueException("__NAME__ (record_id) is required to create a " +
            objectClass.objectClassValue)
}

def sql = new Sql(connection as Connection)

if (sql.firstRow("SELECT count(*) AS n FROM " + table + " WHERE record_id = ?", [recordId]).n > 0) {
    throw new AlreadyExistsException("Record already exists: " + recordId)
}

sql.execute("INSERT INTO " + table + " (record_id, ref_id, last_modified) VALUES (?, ?, current_timestamp())",
        [recordId, createAttributes.hasAttribute("ref_id") ? createAttributes.findString("ref_id") : null])

return new Uid(recordId)
