// Phase-1 acceptance suite (docs/plan.md "Spike execution"), ported from
// idm-config/acceptance-test.sh. The connector inside IDM is the system
// under test, exercised via IDM REST; Databricks state is verified through
// the vendor's own SQL Statement Execution REST API — an independent
// channel, not the connector's JDBC path.
//
// Tests are order-dependent and run sequentially (vitest.config.js).
// Run: cd test && npm test          (PROFILE=lab default)
//      PROFILE=tenant npm test      (phase 3)
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { profile, profileName, preflight } from '../src/profile.js'
import * as idm from '../src/idm.js'
import { sql } from '../src/dbx.js'
import { evidencePath, note } from '../src/http.js'

const T = profile.tables

describe('databricks connector acceptance', () => {
  beforeAll(async () => {
    // Config errors fail here, immediately and by name — a missing token or
    // an unfilled profile placeholder must never masquerade as the
    // readiness timeout below.
    preflight()

    // Readiness gate: after a deploy/restart the connector re-registers, and
    // its first pooled connection does an OAuth exchange against a possibly
    // cold serverless warehouse — routes 404 until that completes. Poll the
    // test action until the facade is live so the suite measures the
    // connector, not its startup latency.
    const deadline = Date.now() + 180_000
    let last = 'no response'
    for (;;) {
      try {
        const r = await idm.connectorTest()
        if (r.json?.ok === true) return
        last = `HTTP ${r.status} ${r.text.slice(0, 160)}`
      } catch (e) {
        last = e.message
      }
      if (Date.now() > deadline) {
        throw new Error(`connector not ready within 180s (profile=${profileName}, ` +
          `${profile.idm.base}) — last response: ${last}`)
      }
      await new Promise((res) => setTimeout(res, 5000))
    }
  }, 200_000)
  it('1. connector test action reports ok', async () => {
    const r = await idm.connectorTest()
    expect(r.json.ok).toBe(true)
    expect(r.json.connectorRef.connectorName).toMatch(/ScriptedSQLConnector/)
  })

  it('2. both object classes exposed from one instance', async () => {
    const r = await idm.systemTest()
    const dbx = r.json.find((s) => s.name === profile.system)
    expect(dbx.objectTypes).toContain('businessRecord')
    expect(dbx.objectTypes).toContain('outboundRecord')
  })

  it('3a. search returns seed rows', async () => {
    const r = await idm.search('businessRecord', 10)
    expect(r.json.result.map((x) => x._id)).toContain('BR-001')
  })

  it('3b. paging cookie present at pageSize=2', async () => {
    const r = await idm.search('businessRecord', 2, 'search businessRecord (paging)')
    expect(r.json.result).toHaveLength(2)
    expect(r.json.pagedResultsCookie).toBeTruthy()
  })

  it('3c. filtered query translates to SQL (eq + sw operators)', async () => {
    const eq = await idm.query('businessRecord', '_id eq "BR-002"', 'filtered search (eq)')
    expect(eq.json.result.map((x) => x._id)).toEqual(['BR-002'])
    const sw = await idm.query('businessRecord', 'record_id sw "BR-"', 'filtered search (sw)')
    expect(sw.json.result.length).toBeGreaterThanOrEqual(3)
  })

  it('4a. create via IDM', async () => {
    const r = await idm.create('businessRecord', { record_id: 'BR-ACC1', ref_id: 'REF-ACC' })
    expect(r.json._id).toBe('BR-ACC1')
  })

  it('4b. read-back via IDM', async () => {
    const r = await idm.read('businessRecord', 'BR-ACC1')
    expect(r.json.ref_id).toBe('REF-ACC')
  })

  it('4c. row visible in Databricks (out-of-band)', async () => {
    const rows = await sql(`SELECT record_id, ref_id FROM ${T.inbound} WHERE record_id='BR-ACC1'`)
    expect(rows).toEqual([['BR-ACC1', 'REF-ACC']])
  })

  it('4d. update ref_id via IDM', async () => {
    const r = await idm.update('businessRecord', 'BR-ACC1', { record_id: 'BR-ACC1', ref_id: 'REF-ACC2' })
    expect(r.json.ref_id).toBe('REF-ACC2')
  })

  it('4e. update visible in Databricks (out-of-band)', async () => {
    const rows = await sql(`SELECT ref_id FROM ${T.inbound} WHERE record_id='BR-ACC1'`)
    expect(rows).toEqual([['REF-ACC2']])
  })

  it('4x. read-only enforcement: client-supplied last_modified is discarded', async () => {
    const r = await idm.update('businessRecord', 'BR-002', {
      record_id: 'BR-002',
      ref_id: 'REF-101',
      last_modified: '1999-01-01T00:00:00.000000Z',
    })
    expect(r.json.last_modified).not.toMatch(/^1999/)
  })

  it('4f. delete via IDM', async () => {
    const r = await idm.remove('businessRecord', 'BR-ACC1')
    expect(r.json._id).toBe('BR-ACC1')
  })

  it('4g. row gone in Databricks (out-of-band)', async () => {
    const rows = await sql(`SELECT count(*) FROM ${T.inbound} WHERE record_id='BR-ACC1'`)
    expect(rows).toEqual([['0']])
  })

  it('5. liveSync consumes out-of-band insert + update + delete (CDF)', async () => {
    const t0 = (await idm.liveSync('businessRecord', 'liveSync (baseline)')).json.connectorData.syncToken
    await sql(`INSERT INTO ${T.inbound} VALUES ('BR-OOB1','REF-OOB',current_timestamp())`, 'out-of-band insert')
    await sql(`UPDATE ${T.inbound} SET ref_id='REF-103', last_modified=current_timestamp() WHERE record_id='BR-001'`, 'out-of-band update')
    await sql(`DELETE FROM ${T.inbound} WHERE record_id='BR-OOB1'`, 'out-of-band delete')
    const t1 = (await idm.liveSync('businessRecord', 'liveSync (after changes)')).json.connectorData.syncToken
    note('liveSync token movement', `baseline=${t0} after=${t1} (expect after >= baseline+3)`)
    expect(t1).toBeGreaterThanOrEqual(t0 + 3)
  })

  it('6a. outbound object class: seed rows on the same instance', async () => {
    const r = await idm.search('outboundRecord', 10)
    expect(r.json.result.map((x) => x._id)).toContain('OB-901')
  })

  it('6b. outbound create on the same instance', async () => {
    const r = await idm.create('outboundRecord', { record_id: 'OB-ACC1', ref_id: 'REF-OB' })
    expect(r.json._id).toBe('OB-ACC1')
    await idm.remove('outboundRecord', 'OB-ACC1')
  })

  afterAll(() => {
    // eslint-disable-next-line no-console
    console.log(`evidence log: ${evidencePath}`)
  })
})
