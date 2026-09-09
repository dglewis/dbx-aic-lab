/*
 * Databricks ScriptedSQL connector — SCHEMA operation.
 * Two object classes named for their datasets (never for flow direction —
 * direction belongs to mappings; see docs/design.md).
 *
 * Read-only set for the spike: last_modified is source-managed
 * (NOT_CREATABLE + NOT_UPDATEABLE — connector-level enforcement, the
 * capability that helped decide ADR-001). The business read-only attribute
 * list remains TBD; extend the flags here when it lands.
 */
package org.forgerock.openicf.connectors.databricks

import static org.identityconnectors.framework.common.objects.AttributeInfo.Flags.NOT_CREATABLE
import static org.identityconnectors.framework.common.objects.AttributeInfo.Flags.NOT_UPDATEABLE
import static org.identityconnectors.framework.common.objects.AttributeInfo.Flags.REQUIRED

import org.forgerock.openicf.connectors.groovy.ICFObjectBuilder
import org.forgerock.openicf.connectors.groovy.OperationType
import org.forgerock.openicf.connectors.scriptedsql.ScriptedSQLConfiguration
import org.identityconnectors.common.logging.Log

def operation = operation as OperationType
def configuration = configuration as ScriptedSQLConfiguration
def log = log as Log
def builder = builder as ICFObjectBuilder

log.info("Entering {0} Script", operation)

builder.schema({
    objectClass {
        type 'businessRecord'
        attributes {
            record_id String.class, REQUIRED
            ref_id String.class
            last_modified String.class, NOT_CREATABLE, NOT_UPDATEABLE
        }
    }
    objectClass {
        type 'outboundRecord'
        attributes {
            record_id String.class, REQUIRED
            ref_id String.class
            last_modified String.class, NOT_CREATABLE, NOT_UPDATEABLE
        }
    }
})
