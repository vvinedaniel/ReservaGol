'use client'

import { createBrowserClient } from '@supabase/ssr'

let client

// Singleton browser client. Uses the publishable (anon) key.
// RLS in PostgreSQL is the real isolation boundary.
export function createClient() {
  if (!client) {
    client = createBrowserClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL,
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
    )
  }
  return client
}
