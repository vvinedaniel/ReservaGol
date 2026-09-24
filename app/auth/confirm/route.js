import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

// Verifies email confirmation / password recovery links.
export async function GET(request) {
  const url = new URL(request.url)
  const token_hash = url.searchParams.get('token_hash')
  const type = url.searchParams.get('type')
  const next = url.searchParams.get('next') || '/dashboard'
  const safeNext = next.startsWith('/') ? next : '/dashboard'

  const supabase = await createClient()

  if (!token_hash || !['email', 'recovery'].includes(type)) {
    return NextResponse.redirect(new URL('/login?error=invalid_link', url))
  }
  const { error } = await supabase.auth.verifyOtp({ token_hash, type })
  if (error) return NextResponse.redirect(new URL('/login?error=expired_link', url))
  return NextResponse.redirect(new URL(safeNext, url))
}
