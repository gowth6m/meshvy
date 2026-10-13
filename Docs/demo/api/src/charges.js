// A charge is money moving once. Everything else in here is a view of that.
const store = new Map()

export const charges = {
  list: () => [...store.values()].sort((a, b) => b.createdAt - a.createdAt),

  create: async (req) => {
    const { amount, currency = 'GBP', customer } = await json(req)
    if (!Number.isInteger(amount) || amount <= 0) {
      throw new Error('amount must be a positive number of minor units')
    }
    const charge = {
      id: `ch_${crypto.randomUUID().slice(0, 12)}`,
      amount,
      currency,
      customer,
      status: 'succeeded',
      createdAt: Date.now(),
    }
    store.set(charge.id, charge)
    return charge
  },

  refund: async (req) => {
    const id = req.url.split('/')[3]
    const charge = store.get(id)
    if (!charge) throw new Error('unknown charge')
    charge.status = 'refunded'
    return charge
  },
}

async function json(req) {
  let raw = ''
  for await (const chunk of req) raw += chunk
  return JSON.parse(raw || '{}')
}
