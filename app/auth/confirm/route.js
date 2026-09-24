import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { safeInternalRedirect } from '@/lib/auth/safe-redirect'

// Verifies email confirmation / password recovery links.
export async function GET(request) {
  const url = new URL(request.url)
  const token_hash = url.searchParams.get('token_hash')
  const type = url.searchParams.get('type')
  // B1: só destinos internos (bloqueia //evil, /\evil, https://..., javascript:, etc.).
  const safeNext = safeInternalRedirect(url.searchParams.get('next'), '/dashboard')

  const supabase = await createClient()

  if (!token_hash || !['email', 'recovery'].includes(type)) {
    return NextResponse.redirect(new URL('/login?error=invalid_link', url))
  }
  const { error } = await supabase.auth.verifyOtp({ token_hash, type })
  if (error) return NextResponse.redirect(new URL('/login?error=expired_link', url))
  return NextResponse.redirect(new URL(safeNext, url))
}
