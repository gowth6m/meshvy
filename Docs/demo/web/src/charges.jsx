import { useEffect, useState } from 'react'

export function Charges() {
  const [rows, setRows] = useState([])
  const [error, setError] = useState(null)

  useEffect(() => {
    fetch('/v1/charges')
      .then((r) => r.json())
      .then(setRows)
      .catch(setError)
  }, [])

  if (error) return <Empty>Could not reach the API.</Empty>
  return <Table rows={rows} />
}
