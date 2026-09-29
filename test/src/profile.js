// Profile loader: PROFILE env var selects test/env/<name>.json (default: lab).
// Profiles hold only non-secret config; secrets resolve by key name from
// secrets/databricks.env (gitignored), which uses shell-style KEY=value lines
// with optional double quotes.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { resolveCredential, tokenProvider } from './dbx-auth.js'

import { testRoot, repoRoot } from './paths.js'
export { repoRoot }

export const profileName = process.env.PROFILE ?? 'lab'
export const profile = JSON.parse(readFileSync(join(testRoot, 'env', `${profileName}.json`), 'utf8'))

function parseEnvFile(path) {
  const out = {}
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/)
    if (!m) continue
    let v = m[2]
    if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1)
    out[m[1]] = v
  }
  return out
}

const secretsEnv = parseEnvFile(join(repoRoot, 'secrets', 'databricks.env'))

// Secrets may come from the process environment (CI, the Linux box) or the
// local secrets file; the process environment wins.
export function secret(key) {
  const v = process.env[key] ?? secretsEnv[key]
  if (v === undefined || v === '') throw new Error(`missing secret/env value: ${key}`)
  return v
}

const dbxHost = secret(profile.databricks.hostEnvKey)
export const databricks = {
  host: dbxHost,
  // Async: yields an Authorization header value (M2M token, or the optional PAT).
  bearer: tokenProvider(
    resolveCredential(profile.databricks.auth, (k) => process.env[k] || secretsEnv[k]),
    dbxHost),
  warehouseId: secret(profile.databricks.warehouseIdFromHttpPathEnvKey).split('/').filter(Boolean).pop(),
}

if (profile.idm.insecureTLS) {
  // Lab-only: IDM 8443 uses a self-signed certificate. Scoped to the test
  // process; tenant/rcs profiles keep full verification.
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
}

// Fail fast on configuration problems, before any polling or retry loop can
// disguise them as timeouts: unfilled profile placeholders and unresolvable
// secrets both surface here, named.
export function preflight() {
  const unfilled = [
    ['idm.base', profile.idm.base],
    ['databricks host', databricks.host],
  ].filter(([, v]) => /[<>]/.test(String(v)))
  if (unfilled.length) {
    throw new Error(
      `profile "${profileName}" has unfilled placeholders: ` +
      unfilled.map(([k, v]) => `${k}="${v}"`).join(', ') +
      ` — edit test/env/${profileName}.json`)
  }
  idmAuthHeader() // throws by name if the configured secret is missing
}

export function idmAuthHeader() {
  const a = profile.idm.auth
  if (a.type === 'basic') {
    return 'Basic ' + Buffer.from(`${a.username}:${a.password}`).toString('base64')
  }
  if (a.type === 'bearer') {
    return 'Bearer ' + secret(a.tokenEnvKey)
  }
  throw new Error(`unknown idm auth type: ${a.type}`)
}
