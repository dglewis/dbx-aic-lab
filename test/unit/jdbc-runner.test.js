// databricks/JdbcRunner.java credential selection (ADR-002), exercised
// through its --describe-auth mode: launches the real source file, no
// driver jar, no network, no secrets.
import { describe, it, expect } from 'vitest'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { repoRoot } from '../src/paths.js'

const java = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', 'java') : 'java'
const runner = join(repoRoot, 'databricks', 'JdbcRunner.java')
const URL = 'jdbc:databricks://ws.example:443;transportMode=http;AuthMech=3;httpPath=/sql/1.0/warehouses/w;UID=token;PWD=old'

function describeAuth(env) {
  const r = spawnSync(java, [runner, '--describe-auth'], {
    env: { PATH: process.env.PATH, DATABRICKS_JDBC_URL: URL, ...env },
    encoding: 'utf8',
  })
  return { code: r.status, out: r.stdout + r.stderr }
}

describe('JdbcRunner --describe-auth', () => {
  it('uses OAuth M2M when the service principal is configured', () => {
    const { code, out } = describeAuth({
      DATABRICKS_SP_CLIENT_ID: 'cid', DATABRICKS_SP_CLIENT_SECRET: 'TOPSECRET', DATABRICKS_PAT: 'dapiX',
    })
    expect(code).toBe(0)
    expect(out).toContain('auth=m2m')
    expect(out).toContain('AuthMech=11;Auth_Flow=1;OAuth2ClientId=cid;OAuth2Secret=***')
    expect(out).not.toMatch(/AuthMech=3|UID=|PWD=/)
    expect(out).not.toMatch(/TOPSECRET|dapiX|ws\.example/)
  })

  it('falls back to the optional PAT when no service principal is configured', () => {
    const { code, out } = describeAuth({ DATABRICKS_PAT: 'dapiX' })
    expect(code).toBe(0)
    expect(out).toContain('auth=pat')
    expect(out).not.toMatch(/dapiX|ws\.example/)
  })

  it('exits 2 naming the variables when no credential is configured', () => {
    const { code, out } = describeAuth({})
    expect(code).toBe(2)
    expect(out).toMatch(/DATABRICKS_SP_CLIENT_ID.*DATABRICKS_SP_CLIENT_SECRET.*DATABRICKS_PAT/)
  })
})
