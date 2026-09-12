// IDM/AIC REST client — same routes in the lab and (via the ported
// provisioner) in an AIC tenant; only base URL and auth differ per profile.
import { profile, idmAuthHeader } from './profile.js'
import { call } from './http.js'

async function idm(label, method, path, body) {
  return call(label, method, `${profile.idm.base}${path}`, {
    headers: {
      Authorization: idmAuthHeader(),
      ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...(method === 'PUT' || method === 'DELETE' ? { 'If-Match': '*' } : {}),
    },
    body,
  })
}

const sys = `/system/${profile.system}`

export const connectorTest = () => idm('connector test', 'POST', `${sys}?_action=test`)
export const systemTest = () => idm('system test (object types)', 'POST', '/system?_action=test')
export const search = (oc, pageSize, label) =>
  idm(label ?? `search ${oc}`, 'GET', `${sys}/${oc}?_queryFilter=true&_pageSize=${pageSize}`)
export const query = (oc, queryFilter, label) =>
  idm(label ?? `query ${oc}`, 'GET', `${sys}/${oc}?_queryFilter=${encodeURIComponent(queryFilter)}`)
export const create = (oc, body) => idm(`create ${oc}/${body.record_id}`, 'POST', `${sys}/${oc}?_action=create`, body)
export const read = (oc, id) => idm(`read ${oc}/${id}`, 'GET', `${sys}/${oc}/${id}`)
export const update = (oc, id, body) => idm(`update ${oc}/${id}`, 'PUT', `${sys}/${oc}/${id}`, body)
export const remove = (oc, id) => idm(`delete ${oc}/${id}`, 'DELETE', `${sys}/${oc}/${id}`)
export const liveSync = (oc, label) => idm(label ?? `liveSync ${oc}`, 'POST', `${sys}/${oc}?_action=liveSync`)
