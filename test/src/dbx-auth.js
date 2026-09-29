// Databricks credential for the out-of-band channel (ADR-002): OAuth M2M as
// a service principal by default, a PAT only when no SP is configured.
// Pure and injectable — no profile or secrets-file access here.

// A token is re-minted once less than this much lifetime remains.
const REFRESH_MARGIN_MS = 5 * 60_000

export function resolveCredential(keys, get) {
  const val = (k) => get(k) || undefined
  const clientId = val(keys.clientIdEnvKey)
  const clientSecret = val(keys.clientSecretEnvKey)
  if (clientId && clientSecret) return { kind: 'm2m', clientId, clientSecret }
  const token = val(keys.patEnvKey)
  if (token) return { kind: 'pat', token }
  throw new Error(
    `no Databricks credential: set ${keys.clientIdEnvKey} + ${keys.clientSecretEnvKey} ` +
    `(OAuth M2M, preferred) or ${keys.patEnvKey} (optional PAT)`)
}

// Returns an async function yielding an Authorization header value. The token
// exchange bypasses the evidence logger on purpose: its request carries the
// client secret and its response the access token.
export function tokenProvider(cred, host, { fetch = globalThis.fetch, now = Date.now } = {}) {
  if (cred.kind === 'pat') return async () => `Bearer ${cred.token}`

  let token
  let expiresAt = 0
  return async () => {
    if (token && now() < expiresAt - REFRESH_MARGIN_MS) return `Bearer ${token}`
    const res = await fetch(`https://${host}/oidc/v1/token`, {
      method: 'POST',
      headers: {
        Authorization: 'Basic ' + Buffer.from(`${cred.clientId}:${cred.clientSecret}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'grant_type=client_credentials&scope=all-apis',
    })
    if (res.status !== 200) {
      throw new Error(`Databricks M2M token exchange failed: HTTP ${res.status}`)
    }
    const json = await res.json()
    token = json.access_token
    expiresAt = now() + json.expires_in * 1000
    return `Bearer ${token}`
  }
}
