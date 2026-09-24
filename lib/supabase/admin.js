import { createClient } from '@supabase/supabase-js'

// Privileged server-only client. Bypasses RLS. NEVER import in a client component.
// Used only for tightly-controlled trusted operations (e.g. creating an org + owner
// membership atomically during onboarding/signup).
export function createAdminClient() {
  return createClient(
    process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_SECRET_KEY,
    { auth: { autoRefreshToken: false, persistSession: false } }
  )
}
