import { batchPayouts } from './payouts.js'
import { deliver } from './webhooks.js'

// Two jobs, one process. Payouts batch on a schedule; webhooks drain a queue
// and retry with a backoff rather than dropping on the first refusal.
const every = (ms, job) => setInterval(() => job().catch(console.error), ms)

every(60_000, batchPayouts)
every(1_000, deliver)

console.log('worker up')
