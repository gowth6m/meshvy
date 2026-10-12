const BACKOFF = [1, 5, 25, 125, 625] // seconds

export async function deliver(queue = []) {
  for (const event of queue) {
    const response = await fetch(event.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(event.payload),
    })
    if (response.ok) continue
    event.attempt = (event.attempt ?? 0) + 1
    event.nextAt = Date.now() + (BACKOFF[event.attempt] ?? 625) * 1000
  }
}
