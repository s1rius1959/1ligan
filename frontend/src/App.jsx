import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'

export default function App() {
  const [categories, setCategories] = useState([])
  const [error, setError] = useState(null)

  useEffect(() => {
    supabase.from('categories').select('*').then(({ data, error }) => {
      if (error) setError(error.message)
      else setCategories(data)
    })
  }, [])

  return (
    <div className="min-h-screen bg-brand-5 p-8">
      <h1 className="text-3xl font-bold text-brand-1">Iligan</h1>
      {error && <p className="text-red-600">{error}</p>}
      <ul className="mt-4 list-disc pl-6">
        {categories.map((c) => <li key={c.id}>{c.name}</li>)}
      </ul>
    </div>
  )
}