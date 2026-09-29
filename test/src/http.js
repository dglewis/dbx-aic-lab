// fetch wrapper with evidence capture: every request/response pair is
// appended to test/runs/acceptance-node-<timestamp>.log — same auditable-proof
// convention as the earlier bash runner, produced from the same code path
// the assertions use. Authorization headers are never logged.
import { appendFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { execSync } from 'node:child_process'
import { repoRoot, profileName, databricks } from './profile.js'

// Evidence stays committable: workspace-identifying values never land in
// the log. Authorization headers are never logged at all (see call()).
const REDACTIONS = [
  [databricks.host, '<workspace-host>'],
  [databricks.warehouseId, '<warehouse-id>'],
]
const scrub = (t) => REDACTIONS.reduce((s, [v, p]) => (v ? s.split(v).join(p) : s), t)

const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
export const evidencePath = join(repoRoot, 'test', 'runs', `acceptance-node-${stamp}.log`)
mkdirSync(join(repoRoot, 'test', 'runs'), { recursive: true })

let commit = 'unknown'
try { commit = execSync('git rev-parse HEAD', { cwd: repoRoot }).toString().trim() } catch {}
appendFileSync(evidencePath,
  `# Node acceptance run ${new Date().toISOString()} profile=${profileName} commit=${commit}\n` +
  `# commands: test/specs/*.test.js at the commit above\n`)

function log(label, text) {
  appendFileSync(evidencePath, `\n=== [${new Date().toISOString()}] ${label}\n${scrub(text)}\n`)
}

export async function call(label, method, url, { headers = {}, body } = {}) {
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  let json
  try { json = JSON.parse(text) } catch { /* non-JSON response */ }
  log(label,
    `${method} ${url}\n` +
    (body !== undefined ? `>> ${JSON.stringify(body)}\n` : '') +
    `<< HTTP ${res.status}\n${text.slice(0, 2000)}`)
  return { status: res.status, text, json }
}

export function note(label, text) {
  log(label, text)
}
