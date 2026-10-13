import { createServer } from 'node:http'
import { charges } from './charges.js'
import { payouts } from './payouts.js'

const PORT = process.env.PORT ?? 8787

const routes = {
  'GET /health': () => ({ ok: true, version: process.env.VERSION ?? 'dev' }),
  'GET /v1/charges': charges.list,
  'POST /v1/charges': charges.create,
  'POST /v1/charges/:id/refund': charges.refund,
  'GET /v1/payouts': payouts.list,
}

createServer(async (req, res) => {
  const handler = routes[`${req.method} ${req.url}`]
  if (!handler) {
    res.writeHead(404, { 'content-type': 'application/json' })
    return res.end(JSON.stringify({ error: 'no such route' }))
  }
  const body = await handler(req)
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}).listen(PORT, () => console.log(`api listening on :${PORT}`))
