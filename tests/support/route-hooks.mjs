// FASE 03C — hooks de módulo (node:module register) para executar o route.js REAL fora do Next.js.
// Resolve o alias "@/..." para o projeto e substitui APENAS as dependências de I/O por stubs que usam
// o cliente gravador exposto pelo teste em globalThis.__p3cRecorder. Nenhuma rede, nenhum banco.
import { pathToFileURL, fileURLToPath } from 'node:url'
import { existsSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const STUBS = {
  'next/server': 'p3c-stub:next-server',
  'next/headers': 'p3c-stub:next-headers',
  '@/lib/supabase/server': 'p3c-stub:supabase-server',
  '@/lib/supabase/admin': 'p3c-stub:supabase-admin',
  '@supabase/supabase-js': 'p3c-stub:supabase-js',
}

function withExt(p) {
  if (existsSync(p) && !p.endsWith('/') && path.extname(p)) return p
  for (const e of ['.js', '.mjs', '.jsx']) if (existsSync(p + e)) return p + e
  for (const e of ['index.js', 'index.mjs']) if (existsSync(path.join(p, e))) return path.join(p, e)
  return p
}

export async function resolve(specifier, context, next) {
  if (STUBS[specifier]) return { url: STUBS[specifier], shortCircuit: true }
  if (specifier.startsWith('@/')) return { url: pathToFileURL(withExt(path.join(ROOT, specifier.slice(2)))).href, shortCircuit: true }
  if ((specifier.startsWith('./') || specifier.startsWith('../')) && context.parentURL?.startsWith('file:')) {
    const p = withExt(path.resolve(path.dirname(fileURLToPath(context.parentURL)), specifier))
    return { url: pathToFileURL(p).href, shortCircuit: true }
  }
  return next(specifier, context)
}

const SRC = {
  'p3c-stub:next-server': `
    export const NextResponse = { json: (body, init = {}) => ({ __json: true, status: init.status || 200, body, headers: new Headers(init.headers || {}) }) }`,
  'p3c-stub:next-headers': `export async function cookies() { return { getAll: () => [], set: () => {} } }`,
  'p3c-stub:supabase-server': `export async function createClient() { return globalThis.__p3cRecorder.client('session') }`,
  'p3c-stub:supabase-admin': `export function createAdminClient() { return globalThis.__p3cRecorder.client('admin') }`,
  'p3c-stub:supabase-js': `export function createClient() { return globalThis.__p3cRecorder.client('token') }`,
}

export async function load(url, context, next) {
  if (SRC[url]) return { format: 'module', source: SRC[url], shortCircuit: true }
  if (url.startsWith('file:') && url.startsWith(pathToFileURL(ROOT).href) && !url.includes('/node_modules/')
      && (url.endsWith('.js') || url.endsWith('.jsx'))) {
    const r = await next(url, { ...context, format: 'module' })
    return { ...r, format: 'module', shortCircuit: true }
  }
  return next(url, context)
}
