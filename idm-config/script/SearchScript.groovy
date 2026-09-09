/*
 * Databricks ScriptedSQL connector — SEARCH operation.
 *
 * Both object classes are single flat tables keyed by record_id, which is
 * ICF __UID__ and __NAME__ at once. Paging orders by record_id and uses the
 * last record_id of a page as the cookie (sortKeys are ignored — one stable
 * natural key). SQL is built as plain String, never GString: groovy.sql.Sql
 * turns GString embeds into prepared-statement parameters, which is wrong
 * for identifiers.
 *
 * Filter translation is table-driven: MapFilterVisitor flattens the ICF
 * Filter into nested maps (operation/left/right/not), and OPERATORS maps
 * each leaf operation to a SQL comparator plus a value shaper; negation
 * flips the comparator via NEGATION. Values only ever bind as ? parameters.
 */
package org.forgerock.openicf.connectors.databricks

import java.sql.Connection
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

import groovy.sql.Sql
import org.forgerock.openicf.connectors.groovy.MapFilterVisitor
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log
import org.identityconnectors.framework.common.objects.ObjectClass
import org.identityconnectors.framework.common.objects.OperationOptions
import org.identityconnectors.framework.common.objects.SearchResult
import org.identityconnectors.framework.common.objects.filter.Filter

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def objectClass = objectClass as ObjectClass
def filter = filter as Filter
def options = options as OperationOptions

log.info("Entering {0} Script for {1}", operation, objectClass)

// Dataset-named object classes -> fully-qualified Delta tables (docs/design.md)
def TABLES = [
        businessRecord: 'workspace.idm_lab.business_records',
        outboundRecord: 'workspace.idm_lab.outbound_records'
]
def table = TABLES[objectClass.objectClassValue]
if (table == null) {
    throw new UnsupportedOperationException(
            "SEARCH is not supported for object class " + objectClass.objectClassValue)
}

// Timestamp interchange format (docs/design.md): UTC, fixed-width microseconds
def TS_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'").withZone(ZoneOffset.UTC)
def formatTs = { ts -> ts == null ? null : TS_FORMAT.format(((java.sql.Timestamp) ts).toInstant()) }

// ICF identifiers -> real column names
def COLUMN_ALIASES = ['__UID__': 'record_id', '__NAME__': 'record_id']

// Leaf operation -> [SQL comparator, value shaper]
def OPERATORS = [
        EQUALS            : ['=', { v -> v }],
        GREATERTHAN       : ['>', { v -> v }],
        GREATERTHANOREQUAL: ['>=', { v -> v }],
        LESSTHAN          : ['<', { v -> v }],
        LESSTHANOREQUAL   : ['<=', { v -> v }],
        CONTAINS          : ['LIKE', { v -> '%' + v + '%' }],
        STARTSWITH        : ['LIKE', { v -> v + '%' }],
        ENDSWITH          : ['LIKE', { v -> '%' + v }],
]
def NEGATION = ['=': '<>', '>': '<=', '>=': '<', '<': '>=', '<=': '>', 'LIKE': 'NOT LIKE']

def whereParams = []
def clauseFor
clauseFor = { node ->
    def op = node.operation as String
    if (op == 'AND' || op == 'OR') {
        return '(' + clauseFor(node.left) + ' ' + op + ' ' + clauseFor(node.right) + ')'
    }
    def spec = OPERATORS[op]
    if (spec == null) {
        throw new UnsupportedOperationException("SEARCH filter operation not supported: " + op)
    }
    def column = COLUMN_ALIASES.getOrDefault(node.left as String, node.left as String)
    def comparator = node.not ? NEGATION[spec[0]] : spec[0]
    whereParams << spec[1](node.right)
    return column + ' ' + comparator + ' ?'
}

def conditions = []
if (options.pagedResultsCookie != null) {
    conditions << 'record_id > ?'
    whereParams.add(0, options.pagedResultsCookie)
}
if (filter != null) {
    conditions << clauseFor(filter.accept(MapFilterVisitor.INSTANCE, null))
    log.ok("Search WHERE conditions: {0}", conditions)
}
def where = conditions ? ' WHERE ' + conditions.join(' AND ') : ''

def limit = options.pageSize != null ? ' LIMIT ' + options.pageSize : ''
def statement = 'SELECT record_id, ref_id, last_modified FROM ' + table +
        where + ' ORDER BY record_id' + limit

def resultCount = 0
def lastRecordId = null
def sql = new Sql(connection as Connection)
sql.eachRow(statement, whereParams, { row ->
    handler {
        uid row.record_id
        id row.record_id
        attribute 'record_id', row.record_id
        attribute 'ref_id', row.ref_id
        attribute 'last_modified', formatTs(row.last_modified)
    }
    lastRecordId = row.record_id
    resultCount++
})

if (limit.isEmpty() || resultCount < options.pageSize) {
    return new SearchResult()
}
return new SearchResult(lastRecordId, -1)
