// Unit tests for Databricks credential selection (ADR-002: OAuth M2M as a
// service principal by default, PAT optional). No network, no secrets —
// fetch and the clock are injected.
import { describe, it, expect, vi } from 'vitest'
import { resolveCredential, tokenProvider } from '../src/dbx-auth.js'

const KEYS = {
  clientIdEnvKey: 'SP_ID',
  clientSecretEnvKey: 'SP_SECRET',
  patEnvKey: 'PAT',
}
const lookup = (vals) => (k) => vals[k]

describe('resolveCredential', () => {
  it('selects M2M when client id and secret are both present', () => {
    expect(resolveCredential(KEYS, lookup({ SP_ID: 'id', SP_SECRET: 's' })))
      .toEqual({ kind: 'm2m', clientId: 'id', clientSecret: 's' })
  })

  it('prefers M2M even when a PAT is also present', () => {
    expect(resolveCredential(KEYS, lookup({ SP_ID: 'id', SP_SECRET: 's', PAT: 'p' })).kind)
      .toBe('m2m')
  })

  it('falls back to the PAT when no service principal is configured', () => {
    expect(resolveCredential(KEYS, lookup({ PAT: 'p' })))
      .toEqual({ kind: 'pat', token: 'p' })
  })

  it('treats empty strings as absent', () => {
    expect(resolveCredential(KEYS, lookup({ SP_ID: '', SP_SECRET: '', PAT: 'p' })).kind)
      .toBe('pat')
  })

  it('names every key when no credential is configured', () => {
    expect(() => resolveCredential(KEYS, lookup({ SP_ID: 'id' })))
      .toThrow(/SP_ID.*SP_SECRET.*PAT/)
  })
})

function tokenResponse(token, expiresIn = 3600) {
  return new Response(JSON.stringify({ access_token: token, expires_in: expiresIn }), { status: 200 })
}

describe('tokenProvider', () => {
  it('returns the PAT as a bearer header without any network call', async () => {
    const fetch = vi.fn()
    const bearer = tokenProvider({ kind: 'pat', token: 'p' }, 'ws.example', { fetch })
    expect(await bearer()).toBe('Bearer p')
    expect(fetch).not.toHaveBeenCalled()
  })

  it('exchanges client credentials at the workspace token endpoint', async () => {
    const fetch = vi.fn(async () => tokenResponse('t1'))
    const bearer = tokenProvider({ kind: 'm2m', clientId: 'id', clientSecret: 's' }, 'ws.example', { fetch })

    expect(await bearer()).toBe('Bearer t1')
    const [url, init] = fetch.mock.calls[0]
    expect(url).toBe('https://ws.example/oidc/v1/token')
    expect(init.method).toBe('POST')
    expect(init.headers.Authorization).toBe('Basic ' + Buffer.from('id:s').toString('base64'))
    expect(String(init.body)).toBe('grant_type=client_credentials&scope=all-apis')
  })

  it('reuses the token until shortly before it expires', async () => {
    let t = 0
    const fetch = vi.fn()
      .mockResolvedValueOnce(tokenResponse('t1', 3600))
      .mockResolvedValueOnce(tokenResponse('t2', 3600))
    const bearer = tokenProvider({ kind: 'm2m', clientId: 'id', clientSecret: 's' }, 'ws.example',
      { fetch, now: () => t })

    expect(await bearer()).toBe('Bearer t1')
    t = 3000_000 // 50 min: still inside the refresh margin
    expect(await bearer()).toBe('Bearer t1')
    t = 3400_000 // under 5 min left: refresh
    expect(await bearer()).toBe('Bearer t2')
    expect(fetch).toHaveBeenCalledTimes(2)
  })

  it('fails with the HTTP status and never echoes the client secret', async () => {
    const fetch = vi.fn(async () => new Response('{"error":"invalid_client"}', { status: 401 }))
    const bearer = tokenProvider({ kind: 'm2m', clientId: 'id', clientSecret: 'TOPSECRET' }, 'ws.example', { fetch })

    const err = await bearer().catch((e) => e)
    expect(err.message).toMatch(/401/)
    expect(err.message).not.toMatch(/TOPSECRET/)
  })
})
