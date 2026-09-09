/*
 * Databricks ScriptedSQL connector — customizer (runs at connector init,
 * before the JDBC pool is built).
 *
 * Assembles the OAuth M2M connection URL in code: reads the service
 * principal's client id/secret from configuration.propertyBag, which the
 * framework populates from the provisioner's customSensitiveConfiguration
 * property (a GuardedString — encrypted at rest by IDM; values reach here
 * already substituted from boot.properties). The secret therefore never
 * appears in any plaintext config property — the ADR-001 auth posture.
 *
 * NOTE (verified empirically against scriptedsql-connector 1.5.20.33): the
 * scripted-sql customizer is a plain script body with `configuration` in
 * the binding — the scripted-REST `customize { init { ... } }` DSL is NOT
 * supported here and breaks script loading.
 *
 * Idempotent: strips any prior auth params before appending, so repeated
 * executions (the framework runs this more than once) converge.
 */
import org.identityconnectors.common.logging.Log

def log = Log.getLog(this.getClass())

def oauth2 = configuration.propertyBag.oauth2
if (oauth2?.clientId && oauth2?.secret) {
    def kept = configuration.url.split(';').findAll { part ->
        !(part ==~ /(?i)(AuthMech|Auth_Flow|OAuth2ClientId|OAuth2Secret|UID|PWD)=.*/)
    }
    configuration.url = (kept.join(';') +
            ';AuthMech=11;Auth_Flow=1' +
            ';OAuth2ClientId=' + oauth2.clientId +
            ';OAuth2Secret=' + oauth2.secret).toString()
    log.info('Databricks connection set to OAuth M2M as service principal {0}', oauth2.clientId)
} else {
    log.warn('No oauth2 clientId/secret in customSensitiveConfiguration; URL left unchanged')
}
