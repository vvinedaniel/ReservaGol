import { NextResponse } from 'next/server'
import { createClient as createTokenClient } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { timeToMin, closeTimeToMin, crossesMidnight, intervalEndMin, buildSlots, overlaps } from '@/lib/reserva/time'
import { RATE_LIMITS, clientIp, consumeRateLimit } from '@/lib/reserva/rate-limit'
import { PUBLIC_ERRORS, isUuid, isValidSlug, isHHMM, isRealDate, checkPublicDate, safeSlotMinutes, publicSlots, findSlot, slotStarted, cleanName, cleanBrPhone, cleanEmail, cleanIdempotencyKey } from '@/lib/reserva/public-booking'

function json(data, status = 200) {
  const res = NextResponse.json(data, { status })
  res.headers.set('Access-Control-Allow-Origin', process.env.CORS_ORIGINS || '*')
  res.headers.set('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
  res.headers.set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
  return res
}

export async function OPTIONS() {
  return json({}, 200)
}

async function getContext(request) {
  // Bearer token (API / future mobile clients): RLS still enforced via the user's JWT.
  const authHeader = request.headers.get('authorization') || ''
  if (authHeader.toLowerCase().startsWith('bearer ')) {
    const token = authHeader.slice(7)
    const supabase = createTokenClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL,
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
      { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } }
    )
    const { data: { user } } = await supabase.auth.getUser(token)
    return { supabase, user }
  }
  // Default: cookie-based Supabase session (browser app).
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  return { supabase, user }
}

async function readBody(request) {
  try { return await request.json() } catch { return {} }
}

// ---- Phase 02A helpers (agenda / reservations) ----
const ARENA_TZ = 'America/Sao_Paulo'
const ARENA_OFFSET = '-03:00' // São Paulo has no DST since 2019; fixed offset. Centralized for future multi-tz.
const CONFLICT_MSG = 'Este horário acabou de ficar indisponível. Escolha outro horário.'

function normalizePhone(p) { return (p || '').replace(/\D/g, '') }
function toISO(date, time) { return `${date}T${(time || '').slice(0, 5)}:00${ARENA_OFFSET}` }
function todayInTZ() { return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()) }
// Violação de integridade multi-tenant (triggers A2): RGT01 = vínculo com outra
// organização/arena; RGT02 = alteração de vínculo estrutural imutável.
// Mensagem genérica: nunca revela IDs, nomes ou dados de outra organização.
const TENANT_MSG = 'Dados da reserva não pertencem à mesma organização.'
function isTenantViolation(error) { return !!error && (error.code === 'RGT01' || error.code === 'RGT02') }
function isConflict(error) {
  const m = (error && (error.message || error.details || '')) + ''
  return !!error && (error.code === '23P01' || m.includes('no_overlap') || m.toLowerCase().includes('overlap') || m.includes('exclusion'))
}

// ---- Phase 02B helpers (public profile / publishing) ----
function slugify(s) {
  return (s || '')
    .toString().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().trim()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
}
function uuid() {
  try { if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID() } catch {}
  return 'x' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10)
}
const MEDIA_BUCKET = 'arena-media'
const MEDIA_MAX = 5 * 1024 * 1024
const MEDIA_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }

// Inspeciona os bytes reais do arquivo (magic numbers) e retorna o mime real
// detectado, ou null se nao for imagem valida. Impede upload de arquivo nao-imagem
// renomeado para .jpg/.png/.webp mesmo com Content-Type forjado.
function sniffImageMime(buf) {
  if (!buf || buf.length < 12) return null
  // JPEG: FF D8 FF
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg'
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47 && buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a) return 'image/png'
  // WEBP: "RIFF"...."WEBP"
  if (buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 && buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50) return 'image/webp'
  return null
}

// Returns the list of missing requirements to publish an arena publicly.
async function publishBlockers(supabase, arena) {
  const missing = []
  if (!arena?.name) missing.push('Nome da arena')
  if (!arena?.slug) missing.push('Link público (slug)')
  if (!arena?.address) missing.push('Endereço')
  if (!arena?.city) missing.push('Cidade')
  if (!(arena?.whatsapp || '').replace(/\D/g, '')) missing.push('WhatsApp')
  if (!arena?.cover_image_url) missing.push('Imagem de capa')
  const { data: courts } = await supabase.from('courts').select('id').eq('arena_id', arena.id).eq('active', true).limit(1)
  if (!courts || courts.length === 0) missing.push('Ao menos 1 quadra ativa')
  const { data: hours } = await supabase.from('business_hours').select('weekday').eq('arena_id', arena.id).eq('closed', false).limit(1)
  if (!hours || hours.length === 0) missing.push('Ao menos 1 dia com horário aberto')
  return missing
}

// ---- Phase 02C helpers (recurring reservations / mensalistas) ----
const RECUR_WINDOW_DAYS = 90
const RECUR_TOPUP_THRESHOLD = 80 // só recarrega quando faltam poucos dias de janela
function pad2(n) { return String(n).padStart(2, '0') }
function weekdayOf(dateStr) { return new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`).getUTCDay() }
function dateAddDays(dateStr, n) {
  const base = new Date(`${dateStr}T12:00:00${ARENA_OFFSET}`)
  const next = new Date(base.getTime() + n * 86400000)
  return new Intl.DateTimeFormat('en-CA', { timeZone: ARENA_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(next)
}
function daysInMonth(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate() } // m 1-based
// Intervalo pode terminar após a meia-noite: end_time < start_time significa "dia seguinte"
// (regra única em lib/reserva/time). end_time = start_time é inválido e é barrado antes.
function endISO(date, startT, endT) { return crossesMidnight(startT, endT) ? toISO(dateAddDays(date, 1), endT) : toISO(date, endT) }
function sameTime(startT, endT) { return timeToMin(startT) === timeToMin(endT) }
const SAME_TIME_MSG = 'Horário final não pode ser igual ao inicial'

// OWNER/MANAGER da organização (ou admin da plataforma). Consulta com o client do usuário (RLS).
async function canManageOrg(supabase, userId, organizationId) {
  if (!organizationId) return false
  const { data: mem } = await supabase.from('organization_members').select('role')
    .eq('user_id', userId).eq('organization_id', organizationId).eq('status', 'ACTIVE').maybeSingle()
  if (mem && ['OWNER', 'MANAGER'].includes(mem.role)) return true
  const { data: prof } = await supabase.from('profiles').select('is_platform_admin').eq('id', userId).maybeSingle()
  return !!prof?.is_platform_admin
}

// Compute the anchor dates (YYYY-MM-DD) for a series within [fromDate, toDate].
function computeAnchors(series, fromDate, toDate) {
  const out = []
  let lower = series.start_date > fromDate ? series.start_date : fromDate
  let upper = toDate
  if (!series.has_no_end_date && series.end_date && series.end_date < upper) upper = series.end_date
  if (lower > upper) return out
  if (series.frequency === 'WEEKLY' || series.frequency === 'BIWEEKLY') {
    const step = series.frequency === 'BIWEEKLY' ? 14 : 7
    const wd = Number(series.weekday)
    // base = first date >= start_date matching weekday
    let base = series.start_date
    for (let i = 0; i < 7; i++) { if (weekdayOf(base) === wd) break; base = dateAddDays(base, 1) }
    let d = base
    while (d <= upper) { if (d >= lower) out.push(d); d = dateAddDays(d, step) }
  } else if (series.frequency === 'MONTHLY') {
    const dom = Number(series.day_of_month)
    let [y, m] = lower.split('-').map(Number) // start iterating at lower's month
    while (true) {
      const dstr = `${y}-${pad2(m)}-${pad2(dom)}`
      if (dstr > upper && !(dom > daysInMonth(y, m))) break
      if (dom <= daysInMonth(y, m) && dstr >= lower && dstr <= upper && dstr >= series.start_date) out.push(dstr)
      m++; if (m > 12) { m = 1; y++ }
      if (`${y}-${pad2(m)}-01` > upper) break
    }
  }
  return out
}

// Dry-run of which anchors can be created vs which conflict. `db` = user-scoped supabase.
// `ignore` = { seriesId, fromDate }: ignora na pré-validação SOMENTE as ocorrências ativas dessa
// série com start_at >= fromDate (as mesmas que o reschedule cancela). Outras séries e reservas
// comuns continuam contando. A constraint anti-overlap segue como autoridade final.
async function previewOccurrences(db, series, fromDate, toDate, ignore = null) {
  const anchors = computeAnchors(series, fromDate, toDate)
  const result = { anchors, toCreate: [], conflicts: [], existing: [] }
  if (!anchors.length) return result
  // business hours map
  const { data: hoursRows } = await db.from('business_hours').select('*').eq('arena_id', series.arena_id)
  const hours = {}; for (const h of (hoursRows || [])) hours[h.weekday] = h
  // existing occurrences of THIS series (skip — idempotent). Only if series persisted.
  const existingSet = new Set()
  if (series.id) {
    const { data: ex } = await db.from('reservations').select('occurrence_date').eq('recurring_reservation_id', series.id).in('occurrence_date', anchors)
    for (const r of (ex || [])) if (r.occurrence_date) existingSet.add(r.occurrence_date)
  }
  // active reservations on this court within the window (for overlap pre-check)
  const first = anchors[0], last = anchors[anchors.length - 1]
  const { data: courtRes } = await db.from('reservations').select('start_at,end_at,status,recurring_reservation_id')
    .eq('court_id', series.court_id).neq('status', 'CANCELLED').neq('status', 'NO_SHOW')
    .gte('start_at', `${dateAddDays(first, -1)}T00:00:00${ARENA_OFFSET}`).lte('start_at', `${last}T23:59:59${ARENA_OFFSET}`) // -1 dia: pega reservas que viram a meia-noite
  const ignoreFrom = ignore ? new Date(`${ignore.fromDate}T00:00:00${ARENA_OFFSET}`).getTime() : null
  const active = (courtRes || []).filter((r) => {
    if (series.id && r.recurring_reservation_id === series.id) return false
    if (ignore && r.recurring_reservation_id === ignore.seriesId && new Date(r.start_at).getTime() >= ignoreFrom) return false
    return true
  })
  const sMin = timeToMin(series.start_time)
  const eMin = intervalEndMin(series.start_time, series.end_time)
  for (const a of anchors) {
    if (existingSet.has(a)) { result.existing.push(a); continue }
    const bh = hours[weekdayOf(a)]
    if (!bh || bh.closed || !bh.open_time || !bh.close_time) { result.conflicts.push({ date: a, reason: 'Fora do horário de funcionamento' }); continue }
    if (sMin < timeToMin(bh.open_time) || eMin > closeTimeToMin(bh.close_time)) { result.conflicts.push({ date: a, reason: 'Fora do horário de funcionamento' }); continue }
    const aStart = new Date(toISO(a, series.start_time)).getTime()
    const aEnd = new Date(endISO(a, series.start_time, series.end_time)).getTime()
    const clash = active.some((r) => new Date(r.start_at).getTime() < aEnd && new Date(r.end_at).getTime() > aStart)
    if (clash) { result.conflicts.push({ date: a, reason: 'Horário já reservado ou bloqueado' }); continue }
    result.toCreate.push(a)
  }
  return result
}

// Insert occurrences (respecting the DB anti-overlap constraint as final authority).
async function materialize(db, series, dates, userId) {
  const created = [], skipped = []
  for (const date of dates) {
    const { error } = await db.from('reservations').insert({
      organization_id: series.organization_id, arena_id: series.arena_id, court_id: series.court_id,
      customer_id: series.customer_id || null,
      start_at: toISO(date, series.start_time), end_at: endISO(date, series.start_time, series.end_time),
      status: 'CONFIRMED', source: 'RECORRENTE', notes: series.notes || null,
      price: series.default_price ?? null, recurring_reservation_id: series.id, occurrence_date: date, created_by: userId,
    })
    if (error) {
      if (error.code === '23505') { /* já materializada — idempotente */ }
      else if (isConflict(error)) skipped.push({ date, reason: 'Horário já reservado ou bloqueado' })
      else skipped.push({ date, reason: 'Não foi possível criar' })
    } else created.push(date)
  }
  return { created, skipped }
}

// Cancel future (not yet played) occurrences of a series. Keeps history intact.
async function cancelFutureOccurrences(db, seriesId, fromDate) {
  const from = fromDate || todayInTZ()
  const { data, error } = await db.from('reservations').update({ status: 'CANCELLED' })
    .eq('recurring_reservation_id', seriesId).neq('status', 'CANCELLED')
    .gte('start_at', `${from}T00:00:00${ARENA_OFFSET}`).select('id')
  if (error) throw error
  return (data || []).length
}

// Opportunistic, idempotent top-up so no-end / long series always have ~90d ahead.
async function topUpSeries(db, series, userId) {
  if (series.status !== 'ACTIVE') return { created: [] }
  const today = todayInTZ()
  const to = dateAddDays(today, RECUR_WINDOW_DAYS)
  const { data: maxRow } = await db.from('reservations').select('occurrence_date')
    .eq('recurring_reservation_id', series.id).order('occurrence_date', { ascending: false }).limit(1).maybeSingle()
  const latest = maxRow?.occurrence_date || null
  if (latest && latest >= dateAddDays(today, RECUR_TOPUP_THRESHOLD)) return { created: [] } // janela ainda cheia
  const from = series.start_date > today ? series.start_date : today
  const prev = await previewOccurrences(db, series, from, to)
  if (!prev.toCreate.length) return { created: [] }
  const res = await materialize(db, series, prev.toCreate, userId)
  return res
}


// Resolve or create a customer within the organization (never across orgs). Phone normalized.
async function resolveCustomerId(supabase, { organization_id, arena_id, customer_id, customer }) {
  if (customer_id) return customer_id
  if (!customer || !customer.name) return null
  const phone = normalizePhone(customer.phone)
  if (phone) {
    const { data: existing } = await supabase.from('customers').select('id').eq('organization_id', organization_id).eq('phone', phone).limit(1).maybeSingle()
    if (existing) return existing.id
  }
  const { data: created, error } = await supabase.from('customers').insert({
    organization_id, arena_id: arena_id || null, name: customer.name, phone: phone || null, email: customer.email || null,
  }).select('id').maybeSingle()
  if (error) throw error
  return created?.id || null
}

async function handleRoute(request, { params }) {
  const { path = [] } = await params
  const resource = path[0] || ''
  const id = path[1]
  const sub = path[2]
  const method = request.method

  try {
    if (resource === 'public') return await handlePublic(request, id, sub, method)
    const { supabase, user } = await getContext(request)
    if (!user) return json({ error: 'Não autenticado' }, 401)
    const url = new URL(request.url)

    // ------------------------------------------------------------------ /me
    if (resource === 'me' && method === 'GET') {
      const { data: profile } = await supabase.from('profiles').select('*').eq('id', user.id).maybeSingle()
      const { data: memberships } = await supabase
        .from('organization_members')
        .select('id, role, status, organization:organizations(*)')
        .eq('user_id', user.id)
        .eq('status', 'ACTIVE')

      const active = memberships && memberships.length ? memberships[0] : null
      const activeOrg = active ? active.organization : null
      return json({
        user: { id: user.id, email: user.email },
        profile: profile || null,
        memberships: memberships || [],
        activeOrg,
        role: active ? active.role : null,
        needsOnboarding: !activeOrg || !activeOrg.onboarding_completed,
      })
    }

    // ---------------------------------------------------------- /onboarding
    if (resource === 'onboarding' && method === 'POST') {
      const body = await readBody(request)
      const admin = createAdminClient()

      // Idempotency: if user already owns a completed org, return it.
      const { data: existing } = await admin
        .from('organization_members')
        .select('organization_id, organizations(onboarding_completed)')
        .eq('user_id', user.id)
        .eq('role', 'OWNER')
        .maybeSingle()
      if (existing && existing.organizations?.onboarding_completed) {
        return json({ organization_id: existing.organization_id, already: true })
      }

      const org = body.organization || {}
      const arena = body.arena || {}
      const courts = Array.isArray(body.courts) ? body.courts : []
      const hours = Array.isArray(body.hours) ? body.hours : []

      if (!org.name || !arena.name) {
        return json({ error: 'Nome da organização e da arena são obrigatórios' }, 400)
      }

      // 1) organization
      const { data: newOrg, error: orgErr } = await admin.from('organizations').insert({
        name: org.name,
        owner_name: org.owner_name || null,
        phone: org.phone || null,
        email: org.email || null,
        is_demo: !!org.is_demo,
        default_reservation_minutes: Number(body.default_reservation_minutes) || 60,
        onboarding_completed: true,
      }).select().single()
      if (orgErr) throw orgErr
      const organization_id = newOrg.id

      // 2) owner membership
      const { error: memErr } = await admin.from('organization_members').insert({
        organization_id, user_id: user.id, role: 'OWNER', status: 'ACTIVE',
      })
      if (memErr) throw memErr

      // 3) profile touch-up
      if (org.owner_name || org.phone) {
        await admin.from('profiles').update({
          full_name: org.owner_name || undefined,
          phone: org.phone || undefined,
        }).eq('id', user.id)
      }

      // 4) arena
      const { data: newArena, error: arenaErr } = await admin.from('arenas').insert({
        organization_id,
        name: arena.name,
        phone: arena.phone || null,
        whatsapp: arena.whatsapp || null,
        address: arena.address || null,
        number: arena.number || null,
        complement: arena.complement || null,
        neighborhood: arena.neighborhood || null,
        city: arena.city || null,
        state: arena.state || null,
        postal_code: arena.postal_code || null,
        latitude: arena.latitude != null ? Number(arena.latitude) : null,
        longitude: arena.longitude != null ? Number(arena.longitude) : null,
        active: true,
      }).select().single()
      if (arenaErr) throw arenaErr

      // 5) courts
      const courtRows = courts.filter((c) => c.name).map((c) => ({
        organization_id, arena_id: newArena.id,
        name: c.name, type: c.type || null, description: c.description || null,
        active: c.active !== false,
      }))
      if (courtRows.length) {
        const { error: courtErr } = await admin.from('courts').insert(courtRows)
        if (courtErr) throw courtErr
      }

      // 6) business hours (0..6)
      const hourRows = []
      for (let wd = 0; wd < 7; wd++) {
        const h = hours.find((x) => Number(x.weekday) === wd) || {}
        hourRows.push({
          organization_id, arena_id: newArena.id, weekday: wd,
          open_time: h.closed ? null : (h.open_time || '08:00'),
          close_time: h.closed ? null : (h.close_time || '23:00'),
          closed: !!h.closed,
        })
      }
      await admin.from('business_hours').insert(hourRows)

      // 7) audit
      await admin.from('audit_logs').insert({
        organization_id, user_id: user.id, action: 'ONBOARDING_COMPLETED',
        entity_type: 'organization', entity_id: organization_id,
      })

      return json({ organization_id })
    }

    // -------------------------------------------------------- /organization
    if (resource === 'organization') {
      if (method === 'GET') {
        const organization_id = url.searchParams.get('organization_id')
        const { data, error } = await supabase.from('organizations').select('*').eq('id', organization_id).maybeSingle()
        if (error) throw error
        return json(data)
      }
      if (method === 'PUT') {
        const body = await readBody(request)
        const patch = {}
        ;['name', 'owner_name', 'phone', 'email', 'default_reservation_minutes'].forEach((k) => {
          if (body[k] !== undefined) patch[k] = body[k]
        })
        const { data, error } = await supabase.from('organizations').update(patch).eq('id', body.organization_id).select().maybeSingle()
        if (error) return json({ error: 'Sem permissão ou dados inválidos' }, 403)
        await supabase.from('audit_logs').insert({ organization_id: body.organization_id, user_id: user.id, action: 'ORG_UPDATED', entity_type: 'organization', entity_id: body.organization_id })
        return json(data)
      }
    }

    // -------------------------------------------------------------- /arenas
    if (resource === 'arenas') {
      if (method === 'GET' && !id) {
        const organization_id = url.searchParams.get('organization_id')
        let q = supabase.from('arenas').select('*').order('created_at', { ascending: true })
        if (organization_id) q = q.eq('organization_id', organization_id)
        const { data, error } = await q
        if (error) throw error
        return json(data || [])
      }
      // ---- Checklist de publicação (autoritativo, mesmo gate do publish) ----
      if (method === 'GET' && id && sub === 'publish-check') {
        const { data: arena } = await supabase.from('arenas').select('*').eq('id', id).maybeSingle()
        if (!arena) return json({ error: 'Arena não encontrada' }, 404)
        const missing = await publishBlockers(supabase, arena)
        return json({ missing, canPublish: missing.length === 0, published: !!arena.public_booking_enabled, slug: arena.slug || null })
      }
      // ---- Upload de imagens (capa / galeria) via Storage (service role) ----
      if (method === 'POST' && id && sub === 'images') {
        // 1) Autorização: só OWNER/MANAGER da org dona da arena.
        const admin = createAdminClient()
        const { data: arena } = await admin.from('arenas').select('id,organization_id,photos').eq('id', id).maybeSingle()
        if (!arena) return json({ error: 'Arena não encontrada' }, 404)
        const { data: mem } = await supabase.from('organization_members').select('role').eq('user_id', user.id).eq('organization_id', arena.organization_id).eq('status', 'ACTIVE').maybeSingle()
        if (!mem || !['OWNER', 'MANAGER', 'PLATFORM_SUPER_ADMIN'].includes(mem.role)) return json({ error: 'Sem permissão para enviar imagens' }, 403)
        // 2) Parse do multipart
        let form
        try { form = await request.formData() } catch { return json({ error: 'Envio inválido' }, 400) }
        const kind = form.get('kind')
        if (kind !== 'cover' && kind !== 'gallery') return json({ error: 'Tipo de imagem inválido' }, 400)
        const files = kind === 'cover' ? [form.get('file')] : form.getAll('files')
        if (!files.length || files.some((f) => !(f instanceof File))) return json({ error: 'Selecione uma imagem' }, 400)
        if (kind === 'gallery' && files.length > 8) return json({ error: 'Máximo de 8 imagens por envio' }, 400)
        for (const f of files) {
          if (!MEDIA_TYPES[f.type]) return json({ error: 'Formato não suportado (use JPG, PNG ou WEBP)' }, 400)
          if (f.size === 0 || f.size > MEDIA_MAX) return json({ error: 'Cada imagem deve ter até 5 MB' }, 400)
        }
        // 3) Upload
        const uploaded = []
        try {
          for (const f of files) {
            const buf = Buffer.from(await f.arrayBuffer())
            const realMime = sniffImageMime(buf)
            if (!realMime || !MEDIA_TYPES[realMime]) throw { _client: 'O arquivo enviado não é uma imagem válida (JPG, PNG ou WEBP).' }
            const ext = MEDIA_TYPES[realMime]
            const path = `${arena.organization_id}/${id}/${kind}/${uuid()}.${ext}`
            const { error: upErr } = await admin.storage.from(MEDIA_BUCKET).upload(path, buf, { contentType: realMime, cacheControl: '31536000', upsert: false })
            if (upErr) throw upErr
            const { data: pub } = admin.storage.from(MEDIA_BUCKET).getPublicUrl(path)
            uploaded.push({ path, url: pub.publicUrl })
          }
          const urls = uploaded.map((u) => u.url)
          let patch
          if (kind === 'cover') patch = { cover_image_url: urls[0] }
          else patch = { photos: [...(Array.isArray(arena.photos) ? arena.photos : []), ...urls].slice(0, 12) }
          const { data: updated } = await admin.from('arenas').update(patch).eq('id', id).select().maybeSingle()
          return json({ kind, urls, arena: updated }, 201)
        } catch (e) {
          await Promise.all(uploaded.map((u) => admin.storage.from(MEDIA_BUCKET).remove([u.path])))
          if (e && e._client) return json({ error: e._client }, 400)
          console.error('Image upload failed:', e?.message || e)
          return json({ error: 'Falha ao enviar a imagem' }, 500)
        }
      }
      if (method === 'PUT' && id) {
        const body = await readBody(request)
        const patch = {}
        ;['name','phone','whatsapp','address','number','complement','neighborhood','city','state','postal_code','latitude','longitude','active','slug','public_booking_enabled','description','cover_image_url','amenities','booking_rules','photos'].forEach((k) => {
          if (body[k] !== undefined) patch[k] = body[k]
        })
        // Normaliza slug
        if (patch.slug !== undefined) {
          patch.slug = slugify(patch.slug)
          if (!patch.slug) return json({ error: 'Link público inválido' }, 400)
        }
        // Validação de publicação: bloqueia se faltarem dados mínimos
        if (patch.public_booking_enabled === true) {
          const { data: current } = await supabase.from('arenas').select('*').eq('id', id).maybeSingle()
          if (!current) return json({ error: 'Arena não encontrada' }, 404)
          const merged = { ...current, ...patch }
          const missing = await publishBlockers(supabase, merged)
          if (missing.length) return json({ error: 'Complete o perfil antes de publicar', missing }, 400)
        }
        const { data, error } = await supabase.from('arenas').update(patch).eq('id', id).select().maybeSingle()
        if (error) {
          if ((error.message || '').includes('arenas_slug_key') || (error.code === '23505')) return json({ error: 'Este link público já está em uso. Escolha outro.' }, 409)
          return json({ error: 'Sem permissão ou dados inválidos' }, 403)
        }
        return json(data)
      }
    }

    // -------------------------------------------------------------- /courts
    if (resource === 'courts') {
      if (method === 'GET') {
        const organization_id = url.searchParams.get('organization_id')
        const arena_id = url.searchParams.get('arena_id')
        let q = supabase.from('courts').select('*, arena:arenas(id,name)').order('created_at', { ascending: true })
        if (organization_id) q = q.eq('organization_id', organization_id)
        if (arena_id) q = q.eq('arena_id', arena_id)
        const { data, error } = await q
        if (error) throw error
        return json(data || [])
      }
      if (method === 'POST') {
        const body = await readBody(request)
        if (!body.name || !body.arena_id || !body.organization_id) {
          return json({ error: 'Nome, arena e organização são obrigatórios' }, 400)
        }
        const { data, error } = await supabase.from('courts').insert({
          organization_id: body.organization_id,
          arena_id: body.arena_id,
          name: body.name,
          type: body.type || null,
          description: body.description || null,
          active: body.active !== false,
        }).select('*, arena:arenas(id,name)').maybeSingle()
        if (isTenantViolation(error)) return json({ error: 'A arena informada não pertence à mesma organização.' }, 400)
        if (error) return json({ error: 'Sem permissão para criar quadra' }, 403)
        await supabase.from('audit_logs').insert({ organization_id: body.organization_id, user_id: user.id, action: 'COURT_CREATED', entity_type: 'court', entity_id: data?.id })
        return json(data, 201)
      }
      if (method === 'PUT' && id) {
        const body = await readBody(request)
        const patch = {}
        ;['name','type','description','active'].forEach((k) => { if (body[k] !== undefined) patch[k] = body[k] })
        const { data, error } = await supabase.from('courts').update(patch).eq('id', id).select('*, arena:arenas(id,name)').maybeSingle()
        if (isTenantViolation(error)) return json({ error: 'A arena informada não pertence à mesma organização.' }, 400)
        if (error) return json({ error: 'Sem permissão ou dados inválidos' }, 403)
        await supabase.from('audit_logs').insert({ organization_id: data?.organization_id, user_id: user.id, action: 'COURT_UPDATED', entity_type: 'court', entity_id: id })
        return json(data)
      }
    }

    // ------------------------------------------------------- /business-hours
    if (resource === 'business-hours') {
      if (method === 'GET') {
        const arena_id = url.searchParams.get('arena_id')
        const { data, error } = await supabase.from('business_hours').select('*').eq('arena_id', arena_id).order('weekday', { ascending: true })
        if (error) throw error
        return json(data || [])
      }
      if (method === 'PUT') {
        const body = await readBody(request)
        const rows = (body.hours || []).map((h) => ({
          organization_id: body.organization_id,
          arena_id: body.arena_id,
          weekday: Number(h.weekday),
          open_time: h.closed ? null : (h.open_time || null),
          close_time: h.closed ? null : (h.close_time || null),
          closed: !!h.closed,
        }))
        const { data, error } = await supabase.from('business_hours').upsert(rows, { onConflict: 'arena_id,weekday' }).select()
        if (isTenantViolation(error)) return json({ error: 'A arena informada não pertence à mesma organização.' }, 400)
        if (error) return json({ error: 'Sem permissão ou dados inválidos' }, 403)
        return json(data || [])
      }
    }

    // ---------------------------------------------------------- /customers
    if (resource === 'customers') {
      const organization_id = url.searchParams.get('organization_id')
      if (method === 'GET') {
        const phone = url.searchParams.get('phone')
        const q = url.searchParams.get('q')
        let query = supabase.from('customers').select('*').eq('organization_id', organization_id).order('name')
        if (phone) query = query.ilike('phone', `%${normalizePhone(phone)}%`)
        const { data, error } = await query.limit(20)
        if (error) throw error
        let rows = data || []
        if (q) { const s = q.toLowerCase(); const ph = normalizePhone(q); rows = rows.filter((c) => (c.name || '').toLowerCase().includes(s) || (c.phone || '').includes(ph)) }
        return json(rows)
      }
      if (method === 'POST') {
        const body = await readBody(request)
        const { data, error } = await supabase.from('customers').insert({ organization_id: body.organization_id, arena_id: body.arena_id || null, name: body.name, phone: normalizePhone(body.phone) || null, email: body.email || null }).select().maybeSingle()
        if (isTenantViolation(error)) return json({ error: 'A arena informada não pertence à mesma organização.' }, 400)
        if (error) return json({ error: 'Não foi possível salvar o cliente' }, 403)
        return json(data, 201)
      }
    }

    // ------------------------------------------------------------- /agenda
    if (resource === 'agenda' && method === 'GET') {
      const arena_id = url.searchParams.get('arena_id')
      const date = url.searchParams.get('date')
      if (!arena_id || !date) return json({ error: 'arena_id e date são obrigatórios' }, 400)
      const { data: arena } = await supabase.from('arenas').select('*').eq('id', arena_id).maybeSingle()
      if (!arena) return json({ error: 'Arena não encontrada' }, 404)
      // Top-up idempotente e guardado das séries ativas desta arena (barato quando a janela já está cheia).
      try {
        const { data: aSeries } = await supabase.from('recurring_reservations').select('*').eq('arena_id', arena_id).eq('status', 'ACTIVE')
        for (const s of (aSeries || [])) { await topUpSeries(supabase, s, user.id) }
      } catch (e) { console.error('agenda topup', e?.message) }
      const [{ data: org }, { data: courts }] = await Promise.all([
        supabase.from('organizations').select('id, default_reservation_minutes').eq('id', arena.organization_id).maybeSingle(),
        supabase.from('courts').select('*').eq('arena_id', arena_id).eq('active', true).order('created_at'),
      ])
      const weekday = new Date(`${date}T12:00:00${ARENA_OFFSET}`).getUTCDay()
      const { data: hoursRows } = await supabase.from('business_hours').select('*').eq('arena_id', arena_id).eq('weekday', weekday).limit(1)
      const { data: reservations } = await supabase.from('reservations')
        .select('*, customer:customers(id,name,phone), court:courts(id,name)')
        .eq('arena_id', arena_id).neq('status', 'CANCELLED')
        .gte('start_at', `${date}T00:00:00${ARENA_OFFSET}`).lte('start_at', `${date}T23:59:59${ARENA_OFFSET}`).order('start_at')
      return json({ arena, courts: courts || [], business_hours: (hoursRows && hoursRows[0]) || null, reservations: reservations || [], default_reservation_minutes: org?.default_reservation_minutes || 60, weekday, timezone: ARENA_TZ })
    }

    // ------------------------------------------------------- /reservations
    if (resource === 'reservations') {
      if (id === 'block' && method === 'POST') {
        const body = await readBody(request)
        if (!body.date || !body.start_time || !body.end_time) return json({ error: 'Dados obrigatórios ausentes' }, 400)
        if (sameTime(body.start_time, body.end_time)) return json({ error: SAME_TIME_MSG }, 400)
        const { data, error } = await supabase.from('reservations').insert({
          organization_id: body.organization_id, arena_id: body.arena_id, court_id: body.court_id, customer_id: null,
          start_at: toISO(body.date, body.start_time), end_at: endISO(body.date, body.start_time, body.end_time),
          status: 'BLOCKED', source: 'INTERNAL', notes: body.reason || 'Bloqueio', created_by: user.id,
        }).select().maybeSingle()
        if (isTenantViolation(error)) return json({ error: TENANT_MSG }, 400)
        if (error) return json({ error: isConflict(error) ? CONFLICT_MSG : 'Não foi possível bloquear o horário' }, isConflict(error) ? 409 : 400)
        await supabase.from('audit_logs').insert({ organization_id: body.organization_id, user_id: user.id, action: 'TIME_BLOCK_CREATED', entity_type: 'reservation', entity_id: data?.id, metadata: { reason: body.reason || null } })
        return json(data, 201)
      }
      if (id && sub === 'cancel' && method === 'POST') {
        const body = await readBody(request)
        const { data: current } = await supabase.from('reservations').select('*').eq('id', id).maybeSingle()
        if (!current) return json({ error: 'Reserva não encontrada' }, 404)
        const notes = body.reason ? `${current.notes ? current.notes + ' | ' : ''}Cancelamento: ${body.reason}` : current.notes
        const { data, error } = await supabase.from('reservations').update({ status: 'CANCELLED', notes }).eq('id', id).select().maybeSingle()
        if (error) return json({ error: 'Não foi possível cancelar a reserva' }, 403)
        const cancelAction = current.recurring_reservation_id ? 'RECURRING_OCCURRENCE_CANCELLED' : 'RESERVATION_CANCELLED'
        await supabase.from('audit_logs').insert({ organization_id: current.organization_id, user_id: user.id, action: cancelAction, entity_type: 'reservation', entity_id: id, metadata: { reason: body.reason || null, recurring_reservation_id: current.recurring_reservation_id || null } })
        return json(data)
      }
      if (id && method === 'PUT') {
        const body = await readBody(request)
        const { data: before } = await supabase.from('reservations').select('recurring_reservation_id').eq('id', id).maybeSingle()
        const patch = {}
        if (body.court_id !== undefined) patch.court_id = body.court_id
        if (body.status !== undefined) patch.status = body.status
        if (body.source !== undefined) patch.source = body.source
        if (body.notes !== undefined) patch.notes = body.notes
        if (body.price !== undefined) patch.price = body.price
        if (body.date && body.start_time && body.end_time && sameTime(body.start_time, body.end_time)) return json({ error: SAME_TIME_MSG }, 400)
        if (body.date && body.start_time) patch.start_at = toISO(body.date, body.start_time)
        if (body.date && body.end_time) patch.end_at = body.start_time ? endISO(body.date, body.start_time, body.end_time) : toISO(body.date, body.end_time)
        if (body.customer_id !== undefined) patch.customer_id = body.customer_id
        else if (body.customer) { try { patch.customer_id = await resolveCustomerId(supabase, { organization_id: body.organization_id, arena_id: body.arena_id, customer: body.customer }) } catch { return json({ error: 'Não foi possível salvar o cliente' }, 400) } }
        // Editar "apenas esta" ocorrência de uma série marca exceção (mantém vínculo p/ histórico).
        if (before?.recurring_reservation_id) patch.is_exception = true
        const { data, error } = await supabase.from('reservations').update(patch).eq('id', id).select('*, customer:customers(id,name,phone), court:courts(id,name)').maybeSingle()
        if (isTenantViolation(error)) return json({ error: TENANT_MSG }, 400)
        if (error) return json({ error: isConflict(error) ? CONFLICT_MSG : 'Não foi possível salvar a reserva' }, isConflict(error) ? 409 : 400)
        const updAction = before?.recurring_reservation_id ? 'RECURRING_OCCURRENCE_UPDATED' : 'RESERVATION_UPDATED'
        await supabase.from('audit_logs').insert({ organization_id: data?.organization_id, user_id: user.id, action: updAction, entity_type: 'reservation', entity_id: id, metadata: { recurring_reservation_id: before?.recurring_reservation_id || null } })
        return json(data)
      }
      if (method === 'POST') {
        const body = await readBody(request)
        if (!body.organization_id || !body.arena_id || !body.court_id || !body.date || !body.start_time || !body.end_time) return json({ error: 'Dados obrigatórios ausentes' }, 400)
        if (sameTime(body.start_time, body.end_time)) return json({ error: SAME_TIME_MSG }, 400)
        let customer_id = null
        try { customer_id = await resolveCustomerId(supabase, body) } catch { return json({ error: 'Não foi possível salvar o cliente' }, 400) }
        const { data, error } = await supabase.from('reservations').insert({
          organization_id: body.organization_id, arena_id: body.arena_id, court_id: body.court_id, customer_id,
          start_at: toISO(body.date, body.start_time), end_at: endISO(body.date, body.start_time, body.end_time),
          status: body.status || 'CONFIRMED', source: body.source || 'RECEPÇÃO', notes: body.notes || null, created_by: user.id,
        }).select('*, customer:customers(id,name,phone), court:courts(id,name)').maybeSingle()
        if (isTenantViolation(error)) return json({ error: TENANT_MSG }, 400)
        if (error) return json({ error: isConflict(error) ? CONFLICT_MSG : 'Não foi possível criar a reserva' }, isConflict(error) ? 409 : 400)
        await supabase.from('audit_logs').insert({ organization_id: body.organization_id, user_id: user.id, action: 'RESERVATION_CREATED', entity_type: 'reservation', entity_id: data?.id })
        return json(data, 201)
      }
      if (method === 'GET') {
        const organization_id = url.searchParams.get('organization_id')
        if (!organization_id) return json({ error: 'organization_id é obrigatório' }, 400)
        const scope = url.searchParams.get('scope')
        const nowISO = new Date().toISOString()
        let query = supabase.from('reservations').select('*, customer:customers(id,name,phone), court:courts(id,name), arena:arenas(id,name)').eq('organization_id', organization_id)
        if (scope === 'today') { const d = todayInTZ(); query = query.gte('start_at', `${d}T00:00:00${ARENA_OFFSET}`).lte('start_at', `${d}T23:59:59${ARENA_OFFSET}`) }
        else if (scope === 'upcoming') { query = query.gte('start_at', nowISO).neq('status', 'CANCELLED') }
        else if (scope === 'past') { query = query.lt('end_at', nowISO).neq('status', 'CANCELLED') }
        else if (scope === 'cancelled') { query = query.eq('status', 'CANCELLED') }
        const date_from = url.searchParams.get('date_from')
        const date_to = url.searchParams.get('date_to')
        if (date_from) query = query.gte('start_at', `${date_from}T00:00:00${ARENA_OFFSET}`)
        if (date_to) query = query.lte('start_at', `${date_to}T23:59:59${ARENA_OFFSET}`)
        const court_id = url.searchParams.get('court_id'); if (court_id) query = query.eq('court_id', court_id)
        const status = url.searchParams.get('status'); if (status) query = query.eq('status', status)
        const source = url.searchParams.get('source'); if (source) query = query.eq('source', source)
        const { data, error } = await query.order('start_at', { ascending: scope !== 'past' }).limit(300)
        if (error) throw error
        let rows = data || []
        const q = url.searchParams.get('q')
        if (q) { const s = q.toLowerCase(); const ph = normalizePhone(q); rows = rows.filter((r) => (r.customer?.name || '').toLowerCase().includes(s) || (r.customer?.phone || '').includes(ph)) }
        return json(rows)
      }
    }

    // -------------------------------------------- /recurring-reservations
    if (resource === 'recurring-reservations') {
      // POST /recurring-reservations  (dry_run=preview | create). skip_conflicts opcional.
      if (method === 'POST' && !id) {
        const body = await readBody(request)
        const req = ['organization_id', 'arena_id', 'court_id', 'frequency', 'start_time', 'end_time', 'start_date']
        for (const k of req) if (!body[k]) return json({ error: 'Dados obrigatórios ausentes' }, 400)
        if (!['WEEKLY', 'BIWEEKLY', 'MONTHLY'].includes(body.frequency)) return json({ error: 'Frequência inválida' }, 400)
        if ((body.frequency === 'WEEKLY' || body.frequency === 'BIWEEKLY') && (body.weekday === undefined || body.weekday === null)) return json({ error: 'Selecione o dia da semana' }, 400)
        if (body.frequency === 'MONTHLY' && !body.day_of_month) return json({ error: 'Selecione o dia do mês' }, 400)
        if (!body.has_no_end_date && !body.end_date) return json({ error: 'Informe a data final ou marque "sem data final"' }, 400)
        if (sameTime(body.start_time, body.end_time)) return json({ error: SAME_TIME_MSG }, 400)

        let customer_id = body.customer_id || null
        if (!customer_id && body.customer) { try { customer_id = await resolveCustomerId(supabase, { organization_id: body.organization_id, arena_id: body.arena_id, customer: body.customer }) } catch { return json({ error: 'Não foi possível salvar o cliente' }, 400) } }

        const transient = {
          id: null, organization_id: body.organization_id, arena_id: body.arena_id, court_id: body.court_id, customer_id,
          frequency: body.frequency, weekday: body.weekday ?? null, day_of_month: body.day_of_month ?? null,
          start_time: body.start_time, end_time: body.end_time, start_date: body.start_date,
          end_date: body.end_date || null, has_no_end_date: !!body.has_no_end_date,
          default_price: body.default_price ?? null, notes: body.notes || null, status: 'ACTIVE',
        }
        const today = todayInTZ()
        const from = transient.start_date > today ? transient.start_date : today
        const to = dateAddDays(today, RECUR_WINDOW_DAYS)
        const prev = await previewOccurrences(supabase, transient, from, to)

        if (body.dry_run) return json({ toCreate: prev.toCreate.length, conflicts: prev.conflicts, dates: prev.toCreate })
        if (prev.conflicts.length && !body.skip_conflicts) return json({ error: 'Conflitos encontrados', conflicts: prev.conflicts, toCreate: prev.toCreate.length, needs_decision: true }, 409)
        if (!prev.toCreate.length && !body.skip_conflicts) return json({ error: 'Nenhuma data disponível para criar', conflicts: prev.conflicts }, 400)

        const { data: series, error: sErr } = await supabase.from('recurring_reservations').insert({
          organization_id: transient.organization_id, arena_id: transient.arena_id, court_id: transient.court_id, customer_id,
          frequency: transient.frequency, weekday: transient.weekday, day_of_month: transient.day_of_month,
          start_time: transient.start_time, end_time: transient.end_time, start_date: transient.start_date,
          end_date: transient.end_date, has_no_end_date: transient.has_no_end_date,
          default_price: transient.default_price, notes: transient.notes, is_demo: !!body.is_demo, created_by: user.id, status: 'ACTIVE',
        }).select().maybeSingle()
        if (sErr || !series) return json({ error: 'Sem permissão para criar mensalista' }, 403)

        const mat = await materialize(supabase, { ...transient, id: series.id }, prev.toCreate, user.id)
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_CREATED', entity_type: 'recurring_reservation', entity_id: series.id, metadata: { frequency: series.frequency, created: mat.created.length, ignored: prev.conflicts.length } })
        return json({ id: series.id, series, created: mat.created.length, ignored: prev.conflicts, skipped: mat.skipped }, 201)
      }

      // GET /recurring-reservations?organization_id=&status=&q=
      if (method === 'GET' && !id) {
        const organization_id = url.searchParams.get('organization_id')
        if (!organization_id) return json({ error: 'organization_id é obrigatório' }, 400)
        // top-up idempotente das séries ativas ao abrir a tela
        const { data: activeSeries } = await supabase.from('recurring_reservations').select('*').eq('organization_id', organization_id).eq('status', 'ACTIVE')
        for (const s of (activeSeries || [])) { try { await topUpSeries(supabase, s, user.id) } catch (e) { console.error('topup', e?.message) } }
        const status = url.searchParams.get('status')
        let q = supabase.from('recurring_reservations').select('*, customer:customers(id,name,phone), court:courts(id,name), arena:arenas(id,name)').eq('organization_id', organization_id).order('created_at', { ascending: false })
        if (status) q = q.eq('status', status)
        const { data, error } = await q
        if (error) throw error
        let rows = data || []
        const search = url.searchParams.get('q')
        if (search) { const s = search.toLowerCase(); const ph = normalizePhone(search); rows = rows.filter((r) => (r.customer?.name || '').toLowerCase().includes(s) || (r.customer?.phone || '').includes(ph)) }
        // next occurrence por série
        const ids = rows.map((r) => r.id)
        const nextByS = {}
        if (ids.length) {
          const nowISO = new Date().toISOString()
          const { data: occ } = await supabase.from('reservations').select('recurring_reservation_id,start_at,occurrence_date').in('recurring_reservation_id', ids).neq('status', 'CANCELLED').gte('start_at', nowISO).order('start_at', { ascending: true })
          for (const o of (occ || [])) { if (!nextByS[o.recurring_reservation_id]) nextByS[o.recurring_reservation_id] = o.start_at }
        }
        return json(rows.map((r) => ({ ...r, next_occurrence: nextByS[r.id] || null })))
      }

      // GET /recurring-reservations/:id  -> detalhe + próximas ocorrências
      if (method === 'GET' && id) {
        const { data: series } = await supabase.from('recurring_reservations').select('*, customer:customers(id,name,phone), court:courts(id,name), arena:arenas(id,name)').eq('id', id).maybeSingle()
        if (!series) return json({ error: 'Mensalista não encontrado' }, 404)
        try { await topUpSeries(supabase, series, user.id) } catch {}
        const nowISO = new Date().toISOString()
        const { data: upcoming } = await supabase.from('reservations').select('id,start_at,end_at,status,is_exception,occurrence_date,court:courts(id,name)').eq('recurring_reservation_id', id).neq('status', 'CANCELLED').gte('start_at', nowISO).order('start_at', { ascending: true }).limit(30)
        return json({ ...series, upcoming: upcoming || [] })
      }

      // PATCH /recurring-reservations/:id  -> editar campos simples da série
      if (method === 'PATCH' && id) {
        const body = await readBody(request)
        const patch = {}
        // customer_id da série é imutável no banco (A2); mudança estrutural só via "Esta e as próximas".
        ;['notes', 'default_price', 'end_date', 'has_no_end_date'].forEach((k) => { if (body[k] !== undefined) patch[k] = body[k] })
        const { data: series, error } = await supabase.from('recurring_reservations').update(patch).eq('id', id).select().maybeSingle()
        if (error || !series) return json({ error: 'Sem permissão para editar mensalista' }, 403)
        try { await topUpSeries(supabase, series, user.id) } catch {}
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_UPDATED', entity_type: 'recurring_reservation', entity_id: id })
        return json(series)
      }

      // POST /recurring-reservations/:id/pause  {cancel_future}
      if (method === 'POST' && id && sub === 'pause') {
        const body = await readBody(request)
        const { data: series, error } = await supabase.from('recurring_reservations').update({ status: 'PAUSED' }).eq('id', id).select().maybeSingle()
        if (error || !series) return json({ error: 'Sem permissão' }, 403)
        let cancelled = 0
        if (body.cancel_future) cancelled = await cancelFutureOccurrences(supabase, id)
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_PAUSED', entity_type: 'recurring_reservation', entity_id: id, metadata: { cancelled_future: cancelled } })
        return json({ series, cancelled_future: cancelled })
      }

      // POST /recurring-reservations/:id/reactivate
      if (method === 'POST' && id && sub === 'reactivate') {
        const { data: series, error } = await supabase.from('recurring_reservations').update({ status: 'ACTIVE' }).eq('id', id).select().maybeSingle()
        if (error || !series) return json({ error: 'Sem permissão' }, 403)
        const mat = await topUpSeries(supabase, series, user.id)
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_REACTIVATED', entity_type: 'recurring_reservation', entity_id: id, metadata: { created: (mat.created || []).length } })
        return json({ series, created: (mat.created || []).length })
      }

      // POST /recurring-reservations/:id/cancel
      if (method === 'POST' && id && sub === 'cancel') {
        const { data: series, error } = await supabase.from('recurring_reservations').update({ status: 'CANCELLED' }).eq('id', id).select().maybeSingle()
        if (error || !series) return json({ error: 'Sem permissão' }, 403)
        const cancelled = await cancelFutureOccurrences(supabase, id)
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_CANCELLED', entity_type: 'recurring_reservation', entity_id: id, metadata: { cancelled_future: cancelled } })
        return json({ series, cancelled_future: cancelled })
      }

      // POST /recurring-reservations/:id/generate  -> botão "Gerar próximas"
      if (method === 'POST' && id && sub === 'generate') {
        const { data: series } = await supabase.from('recurring_reservations').select('*').eq('id', id).maybeSingle()
        if (!series) return json({ error: 'Mensalista não encontrado' }, 404)
        if (series.status !== 'ACTIVE') return json({ error: 'A série precisa estar ativa para gerar novas reservas' }, 400)
        const today = todayInTZ()
        const from = series.start_date > today ? series.start_date : today
        const prev = await previewOccurrences(supabase, series, from, dateAddDays(today, RECUR_WINDOW_DAYS))
        const mat = await materialize(supabase, series, prev.toCreate, user.id)
        return json({ created: mat.created.length, conflicts: prev.conflicts })
      }

      // POST /recurring-reservations/:id/reschedule  -> "esta e as próximas"
      // Ordem segura: permissão -> pré-validação -> encerra série antiga -> cria nova série
      // (restaura a antiga se falhar) -> só então cancela ocorrências futuras -> materializa.
      // Ainda NÃO é atômico (sem transação/RPC): dívida técnica registrada.
      if (method === 'POST' && id && sub === 'reschedule') {
        const body = await readBody(request)
        const from_date = body.from_date
        if (!from_date) return json({ error: 'from_date é obrigatório' }, 400)
        const { data: old } = await supabase.from('recurring_reservations').select('*').eq('id', id).maybeSingle()
        if (!old) return json({ error: 'Mensalista não encontrado' }, 404)
        // 1) Permissão ANTES de qualquer alteração (RECEPTIONIST -> 403, nada é tocado).
        if (!(await canManageOrg(supabase, user.id, old.organization_id))) return json({ error: 'Sem permissão para reagendar mensalista' }, 403)
        // Nova série (a partir de from_date) copiando campos e aplicando mudanças.
        const next = {
          id: null, organization_id: old.organization_id, arena_id: old.arena_id,
          court_id: body.court_id || old.court_id, customer_id: old.customer_id,
          frequency: body.frequency || old.frequency,
          weekday: body.weekday !== undefined ? body.weekday : old.weekday,
          day_of_month: body.day_of_month !== undefined ? body.day_of_month : old.day_of_month,
          start_time: body.start_time || old.start_time, end_time: body.end_time || old.end_time,
          start_date: from_date, end_date: old.end_date, has_no_end_date: old.has_no_end_date,
          default_price: body.default_price !== undefined ? body.default_price : old.default_price,
          notes: body.notes !== undefined ? body.notes : old.notes, status: 'ACTIVE',
        }
        if (sameTime(next.start_time, next.end_time)) return json({ error: SAME_TIME_MSG }, 400)
        const today = todayInTZ()
        const from = next.start_date > today ? next.start_date : today
        const to = dateAddDays(today, RECUR_WINDOW_DAYS)
        // 2) Pré-validação ignorando apenas as ocorrências da própria série antiga a partir de from_date.
        const prev = await previewOccurrences(supabase, next, from, to, { seriesId: id, fromDate: from_date })
        if (body.dry_run) return json({ toCreate: prev.toCreate.length, conflicts: prev.conflicts })
        if (prev.conflicts.length && !body.skip_conflicts) return json({ error: 'Conflitos encontrados', conflicts: prev.conflicts, toCreate: prev.toCreate.length, needs_decision: true }, 409)
        // 3) Encerra a série antiga em from_date-1 (ou cancela, se reagendada desde o início).
        //    RLS filtra UPDATE sem erro: exigir a linha de volta; sem ela, PARA aqui.
        const oldEnd = dateAddDays(from_date, -1)
        const oldPatch = oldEnd < old.start_date ? { status: 'CANCELLED' } : { end_date: oldEnd, has_no_end_date: false }
        const { data: oldUpd, error: oldErr } = await supabase.from('recurring_reservations').update(oldPatch).eq('id', id).select('id').maybeSingle()
        if (oldErr || !oldUpd) return json({ error: 'Não foi possível atualizar a série atual. Nenhuma reserva foi alterada.' }, 403)
        // 4) Cria a nova série. Se falhar, restaura a antiga e para (nenhuma ocorrência foi cancelada).
        const { data: series, error: sErr } = await supabase.from('recurring_reservations').insert({
          organization_id: next.organization_id, arena_id: next.arena_id, court_id: next.court_id, customer_id: next.customer_id,
          frequency: next.frequency, weekday: next.weekday, day_of_month: next.day_of_month,
          start_time: next.start_time, end_time: next.end_time, start_date: next.start_date, end_date: next.end_date,
          has_no_end_date: next.has_no_end_date, default_price: next.default_price, notes: next.notes, is_demo: old.is_demo, created_by: user.id, status: 'ACTIVE',
        }).select().maybeSingle()
        if (sErr || !series) {
          const { error: revertErr } = await supabase.from('recurring_reservations').update({ status: old.status, end_date: old.end_date, has_no_end_date: old.has_no_end_date }).eq('id', id)
          if (revertErr) console.error('reschedule revert failed', id, revertErr.message)
          return json({ error: 'Não foi possível criar a nova série. Nenhuma reserva foi alterada.' }, 400)
        }
        // 5) Só agora cancela as ocorrências futuras da série antiga e materializa a nova.
        let cancelled = 0
        try { cancelled = await cancelFutureOccurrences(supabase, id, from_date) }
        catch (e) {
          console.error('reschedule cancel failed', id, e?.message)
          return json({ error: 'Nova série criada, mas não foi possível liberar as reservas antigas. Revise o mensalista.', id: series.id }, 500)
        }
        const mat = await materialize(supabase, { ...next, id: series.id }, prev.toCreate, user.id)
        await supabase.from('audit_logs').insert({ organization_id: series.organization_id, user_id: user.id, action: 'RECURRING_RESERVATION_UPDATED', entity_type: 'recurring_reservation', entity_id: id, metadata: { rescheduled_from: from_date, new_series: series.id, created: mat.created.length, cancelled_future: cancelled } })
        return json({ id: series.id, series, previous: id, created: mat.created.length, ignored: prev.conflicts, skipped: mat.skipped }, 201)
      }
    }


    return json({ error: `Rota /${path.join('/')} não encontrada` }, 404)
  } catch (error) {
    console.error('API Error:', error?.message || error)
    return json({ error: 'Erro interno do servidor' }, 500)
  }
}

export const GET = handleRoute
export const POST = handleRoute
export const PUT = handleRoute
export const PATCH = handleRoute
export const DELETE = handleRoute

// ============================ PHASE 02B: PUBLIC API ============================
// Resposta pública que nunca deve ser guardada em cache (navegador, proxy ou CDN).
function jsonNoStore(data, status = 200) {
  const res = json(data, status)
  res.headers.set('Cache-Control', 'no-store')
  return res
}
// A6: respostas do rate limit persistente (sem scope, contagem, hash, telefone ou IP).
function tooManyRequests(retryAfter) {
  const res = jsonNoStore({ error: 'Muitas tentativas. Aguarde alguns minutos e tente novamente.' }, 429)
  res.headers.set('Retry-After', String(retryAfter))
  return res
}
// Limiter indisponível (RPC/secret/resposta inválida): NUNCA fail-open.
function limiterUnavailable(where, err) {
  console.error(`Rate limiter indisponível (${where}):`, err?.message || 'sem identificador utilizável')
  return jsonNoStore({ error: 'Serviço temporariamente indisponível. Tente novamente em instantes.' }, 503)
}
function genCode() { const a = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let s = ''; for (let i = 0; i < 6; i++) s += a[Math.floor(Math.random() * a.length)]; return 'RG-' + s }

async function loadPublicArena(admin, slug) {
  const { data } = await admin.from('arenas').select('*').eq('slug', slug).eq('active', true).eq('public_booking_enabled', true).maybeSingle()
  return data
}
function sanitizeArena(a, courts) {
  return {
    slug: a.slug, name: a.name, description: a.description, address: a.address, number: a.number,
    neighborhood: a.neighborhood, city: a.city, state: a.state, whatsapp: a.whatsapp,
    latitude: a.latitude, longitude: a.longitude, cover_image_url: a.cover_image_url,
    amenities: a.amenities || [], booking_rules: a.booking_rules, photos: a.photos || [],
    courts: (courts || []).map((c) => ({ id: c.id, name: c.name, type: c.type })),
  }
}

async function handlePublic(request, id, sub, method) {
  const admin = createAdminClient()
  const url = new URL(request.url)
  try {
    if (id === 'arenas' && method === 'GET') {
      const { data: arenas } = await admin.from('arenas').select('id,slug,name,description,neighborhood,city,state,cover_image_url').eq('active', true).eq('public_booking_enabled', true).limit(60)
      const list = arenas || []
      const ids = list.map((a) => a.id)
      let byArena = {}
      if (ids.length) { const { data: courts } = await admin.from('courts').select('arena_id,type').in('arena_id', ids).eq('active', true); for (const c of (courts || [])) { byArena[c.arena_id] = byArena[c.arena_id] || { n: 0, types: new Set() }; byArena[c.arena_id].n++; byArena[c.arena_id].types.add(c.type) } }
      const q = (url.searchParams.get('q') || '').toLowerCase()
      let out = list.map((a) => ({ slug: a.slug, name: a.name, description: a.description, neighborhood: a.neighborhood, city: a.city, state: a.state, cover_image_url: a.cover_image_url, courts_count: byArena[a.id]?.n || 0, types: Array.from(byArena[a.id]?.types || []) }))
      if (q) out = out.filter((a) => (a.name || '').toLowerCase().includes(q) || (a.city || '').toLowerCase().includes(q) || (a.neighborhood || '').toLowerCase().includes(q))
      return json(out)
    }
    if (id === 'arena' && sub && method === 'GET') {
      const a = await loadPublicArena(admin, sub)
      if (!a) return json({ error: 'Arena não encontrada' }, 404)
      const { data: courts } = await admin.from('courts').select('id,name,type').eq('arena_id', a.id).eq('active', true).order('created_at')
      const { data: hours } = await admin.from('business_hours').select('weekday,open_time,close_time,closed').eq('arena_id', a.id).order('weekday')
      return json({ ...sanitizeArena(a, courts), business_hours: hours || [] })
    }
    if (id === 'availability' && method === 'GET') {
      const slug = url.searchParams.get('slug'); const court_id = url.searchParams.get('court_id'); const date = url.searchParams.get('date')
      // Formato validado ANTES de qualquer consulta (A4).
      if (!isValidSlug(slug) || !isUuid(court_id)) return json({ error: PUBLIC_ERRORS.params }, 400)
      const dateErr = checkPublicDate(date, todayInTZ())
      if (dateErr) return json({ error: PUBLIC_ERRORS[dateErr] }, 400)
      const a = await loadPublicArena(admin, slug)
      if (!a) return json({ error: 'Arena indisponível' }, 404)
      const { data: court } = await admin.from('courts').select('id').eq('id', court_id).eq('arena_id', a.id).eq('active', true).maybeSingle()
      if (!court) return json({ error: 'Quadra indisponível' }, 404)
      const weekday = new Date(`${date}T12:00:00${ARENA_OFFSET}`).getUTCDay()
      const { data: bh } = await admin.from('business_hours').select('*').eq('arena_id', a.id).eq('weekday', weekday).maybeSingle()
      if (!bh || bh.closed) return json({ closed: true, slots: [] })
      const { data: org } = await admin.from('organizations').select('default_reservation_minutes').eq('id', a.organization_id).maybeSingle()
      const minutes = safeSlotMinutes(org?.default_reservation_minutes)
      if (!minutes) return json({ error: PUBLIC_ERRORS.config }, 503) // configuração inválida: nunca gera slots
      const slots = publicSlots(bh, minutes) // close 00:00 = meia-noite
      const { data: res } = await admin.from('reservations').select('start_at,end_at,status').eq('court_id', court_id).neq('status', 'CANCELLED').gte('start_at', `${date}T00:00:00${ARENA_OFFSET}`).lte('start_at', `${date}T23:59:59${ARENA_OFFSET}`)
      const now = Date.now()
      // Horário já iniciado (hoje) nunca aparece como disponível.
      const out = slots.map((s) => ({ start: s.start, end: s.end, available: !slotStarted(date, s.start, now) && !(res || []).some((r) => overlaps(r, s.startMin, s.endMin)) }))
      return json({ closed: false, slots: out })
    }
    if (id === 'reserve' && method === 'POST') {
      const raw = await readBody(request)
      const body = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
      // 1) Formato de TODOS os campos, sem consultar o banco (A4). Nada é criado se falhar.
      if (!isValidSlug(body.slug) || !isUuid(body.court_id) || !isHHMM(body.start_time) || !isHHMM(body.end_time)) return json({ error: PUBLIC_ERRORS.params }, 400)
      if (!isRealDate(body.date)) return json({ error: PUBLIC_ERRORS.date }, 400)
      const name = cleanName(body.name)
      if (!name) return json({ error: PUBLIC_ERRORS.name }, 400)
      const phone = cleanBrPhone(body.phone)
      if (!phone) return json({ error: PUBLIC_ERRORS.phone }, 400)
      const email = cleanEmail(body.email)
      if (!email.ok) return json({ error: PUBLIC_ERRORS.email }, 400)
      if (body.accept_terms !== true) return json({ error: PUBLIC_ERRORS.terms }, 400) // booleano true estrito
      const idem = cleanIdempotencyKey(body.idempotency_key)
      if (!idem.ok) return json({ error: PUBLIC_ERRORS.idempotency }, 400)
      // 2) Arena publicada e quadra ativa da própria arena.
      const a = await loadPublicArena(admin, body.slug)
      if (!a) return json({ error: 'Arena indisponível' }, 404)
      const { data: court } = await admin.from('courts').select('id').eq('id', body.court_id).eq('arena_id', a.id).eq('active', true).maybeSingle()
      if (!court) return json({ error: 'Quadra indisponível' }, 404)
      // 3) Idempotência (escopo por arena, alinhado ao índice único (arena_id, idempotency_key)).
      //    Mesmo ponto de antes (depois de arena/quadra): um retry legítimo da MESMA chave
      //    devolve a reserva já criada mesmo que, segundos depois, o slot já tenha começado.
      if (idem.value) { const { data: ex } = await admin.from('reservations').select('public_code').eq('arena_id', a.id).eq('idempotency_key', idem.value).maybeSingle(); if (ex) return json({ public_code: ex.public_code, idempotent: true }) }
      // 4) Janela de data, expediente e slot REAL gerado pelo servidor.
      const dateErr = checkPublicDate(body.date, todayInTZ())
      if (dateErr) return json({ error: PUBLIC_ERRORS[dateErr] }, 400)
      const weekday = new Date(`${body.date}T12:00:00${ARENA_OFFSET}`).getUTCDay()
      const { data: bh } = await admin.from('business_hours').select('*').eq('arena_id', a.id).eq('weekday', weekday).maybeSingle()
      if (!bh || bh.closed) return json({ error: PUBLIC_ERRORS.closed }, 400)
      const { data: org } = await admin.from('organizations').select('default_reservation_minutes').eq('id', a.organization_id).maybeSingle()
      const minutes = safeSlotMinutes(org?.default_reservation_minutes)
      if (!minutes) return json({ error: PUBLIC_ERRORS.config }, 503)
      const slot = findSlot(publicSlots(bh, minutes), body.start_time, body.end_time) // par EXATO, nunca só a duração
      if (!slot) return json({ error: PUBLIC_ERRORS.slot }, 400)
      if (slotStarted(body.date, slot.start, Date.now())) return json({ error: PUBLIC_ERRORS.slotPast }, 400)
      // A6: só tentativas NOVAS e VÁLIDAS consomem quota (retry idempotente já retornou acima).
      // Primário: arena + telefone. Secundário: arena + IP (quando houver IP utilizável).
      // Os dois buckets são consumidos (tentativa real); qualquer um bloqueado -> 429.
      try {
        const ip = clientIp(request.headers)
        const checks = [consumeRateLimit(admin, RATE_LIMITS.RESERVE_PHONE, [a.id, phone])]
        if (ip) checks.push(consumeRateLimit(admin, RATE_LIMITS.RESERVE_IP, [a.id, ip]))
        const blocked = (await Promise.all(checks)).filter((r) => !r.allowed)
        if (blocked.length) return tooManyRequests(Math.max(...blocked.map((r) => r.retryAfter)))
      } catch (e) {
        return limiterUnavailable('reserve', e)
      }
      // 5) Só agora: cliente (dedup por telefone dentro da organização) e reserva.
      //    A constraint reservations_no_overlap continua sendo a autoridade final (409).
      let customer_id = null
      const { data: exc } = await admin.from('customers').select('id').eq('organization_id', a.organization_id).eq('phone', phone).limit(1).maybeSingle()
      if (exc) customer_id = exc.id
      else { const { data: nc } = await admin.from('customers').insert({ organization_id: a.organization_id, arena_id: a.id, name, phone, email: email.value }).select('id').maybeSingle(); customer_id = nc?.id || null }
      const public_code = genCode()
      const { data: created, error } = await admin.from('reservations').insert({
        organization_id: a.organization_id, arena_id: a.id, court_id: body.court_id, customer_id,
        start_at: toISO(body.date, slot.start), end_at: endISO(body.date, slot.start, slot.end),
        status: 'CONFIRMED', source: 'PUBLIC_WEB', notes: null, public_code, idempotency_key: idem.value,
      }).select('public_code').maybeSingle()
      if (error) {
        if (isConflict(error)) return json({ error: 'Este horário acabou de ser reservado. Escolha outro horário.' }, 409)
        // Corrida de idempotência: dois cliques quase simultâneos com a mesma chave
        if (error.code === '23505' && idem.value) { const { data: ex2 } = await admin.from('reservations').select('public_code').eq('arena_id', a.id).eq('idempotency_key', idem.value).maybeSingle(); if (ex2) return json({ public_code: ex2.public_code, idempotent: true }) }
        return json({ error: 'Não foi possível concluir a reserva' }, 400)
      }
      await admin.from('audit_logs').insert({ organization_id: a.organization_id, user_id: null, action: 'PUBLIC_RESERVATION_CREATED', entity_type: 'reservation', entity_id: null, metadata: { arena_id: a.id, court_id: body.court_id, public_code, source: 'PUBLIC_WEB' } })
      return json({ public_code }, 201)
    }
    if (id === 'reservation' && sub && method === 'GET') {
      // A6: rate limit por IP ANTES de qualquer consulta. Sem IP utilizável -> 503 (fail-closed).
      const lookupIp = clientIp(request.headers)
      if (!lookupIp) return limiterUnavailable('lookup')
      try {
        const rl = await consumeRateLimit(admin, RATE_LIMITS.LOOKUP_IP, [lookupIp])
        if (!rl.allowed) return tooManyRequests(rl.retryAfter)
      } catch (e) {
        return limiterUnavailable('lookup', e)
      }
      // A5: sem identidade de cliente (o customer_id pode ser um cadastro pré-existente
      // reaproveitado pelo telefone). Só reservas realmente públicas; allowlist explícita;
      // mesmo 404 para código inexistente ou não público; nunca em cache.
      const { data: r } = await admin.from('reservations')
        .select('public_code,start_at,end_at,status,court:courts(name),arena:arenas(name,slug,address,number,neighborhood,city,state,whatsapp,latitude,longitude)')
        .eq('public_code', sub).eq('source', 'PUBLIC_WEB').maybeSingle()
      if (!r) return jsonNoStore({ error: 'Reserva não encontrada' }, 404)
      const a = r.arena || {}
      return jsonNoStore({
        public_code: r.public_code, start_at: r.start_at, end_at: r.end_at, status: r.status,
        court: { name: r.court?.name ?? null },
        arena: {
          name: a.name ?? null, slug: a.slug ?? null, address: a.address ?? null, number: a.number ?? null,
          neighborhood: a.neighborhood ?? null, city: a.city ?? null, state: a.state ?? null,
          whatsapp: a.whatsapp ?? null, latitude: a.latitude ?? null, longitude: a.longitude ?? null,
        },
      })
    }
    return json({ error: 'Rota pública não encontrada' }, 404)
  } catch (e) {
    console.error('Public API Error:', e?.message || e)
    return json({ error: 'Erro interno do servidor' }, 500)
  }
}
