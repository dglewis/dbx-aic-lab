// Databricks-native out-of-band channel: the SQL Statement Execution REST
// API (POST /api/2.0/sql/statements). Deliberately independent of the JDBC
// path the connector uses — vendor tooling verifies, the connector is what's
// under test. (Same-driver fault isolation stays with databricks/smoke-test.sh.)
import { databricks } from './profile.js'
import { call } from './http.js'

const base = `https://${databricks.host}/api/2.0/sql/statements`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export async function sql(statement, label = 'out-of-band SQL') {
  let r = await call(label, 'POST', base, {
    headers: { Authorization: await databricks.bearer(), 'Content-Type': 'application/json' },
    body: {
      statement,
      warehouse_id: databricks.warehouseId,
      wait_timeout: '30s',
      on_wait_timeout: 'CONTINUE',
    },
  })
  let state = r.json?.status?.state
  const id = r.json?.statement_id
  while (state === 'PENDING' || state === 'RUNNING') {
    await sleep(2000)
    r = await call(`${label} (poll)`, 'GET', `${base}/${id}`, { headers: { Authorization: await databricks.bearer() } })
    state = r.json?.status?.state
  }
  if (state !== 'SUCCEEDED') {
    throw new Error(`statement ${state}: ${JSON.stringify(r.json?.status ?? r.json).slice(0, 400)}`)
  }
  return r.json.result?.data_array ?? []
}
