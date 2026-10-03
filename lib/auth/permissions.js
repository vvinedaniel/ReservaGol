// Centralized authorization structure for Reserva Gol.
// Do NOT scatter permission logic across the frontend; use these helpers.

export const ROLES = {
  PLATFORM_SUPER_ADMIN: 'PLATFORM_SUPER_ADMIN',
  OWNER: 'OWNER',
  MANAGER: 'MANAGER',
  RECEPTIONIST: 'RECEPTIONIST',
}

// Feature keys used across the panel.
export const FEATURES = {
  DASHBOARD: 'dashboard',
  AGENDA: 'agenda',
  RESERVATIONS: 'reservations',
  MENSALISTAS: 'mensalistas',
  COURTS: 'courts',
  CUSTOMERS: 'customers',
  FINANCE: 'finance',
  REPORTS: 'reports',
  CAMPAIGNS: 'campaigns',
  TEAM: 'team',
  SETTINGS_ORG: 'settings_org',
  SETTINGS_ARENA: 'settings_arena',
  SETTINGS_HOURS: 'settings_hours',
  SETTINGS_USER: 'settings_user',
}

// Permission matrix: role -> set of allowed features.
const MATRIX = {
  [ROLES.PLATFORM_SUPER_ADMIN]: new Set(Object.values(FEATURES)),
  [ROLES.OWNER]: new Set(Object.values(FEATURES)),
  [ROLES.MANAGER]: new Set([
    FEATURES.DASHBOARD,
    FEATURES.AGENDA,
    FEATURES.RESERVATIONS,
    FEATURES.MENSALISTAS,
    FEATURES.COURTS,
    FEATURES.CUSTOMERS,
    FEATURES.FINANCE,
    FEATURES.REPORTS,
    FEATURES.SETTINGS_ARENA,
    FEATURES.SETTINGS_HOURS,
    FEATURES.SETTINGS_USER,
  ]),
  [ROLES.RECEPTIONIST]: new Set([
    FEATURES.AGENDA,
    FEATURES.RESERVATIONS,
    FEATURES.MENSALISTAS,
    FEATURES.CUSTOMERS,
    FEATURES.SETTINGS_USER,
  ]),
}

export function can(role, feature) {
  if (!role) return false
  const allowed = MATRIX[role]
  return allowed ? allowed.has(feature) : false
}

export function isManagerOrAbove(role) {
  return [ROLES.PLATFORM_SUPER_ADMIN, ROLES.OWNER, ROLES.MANAGER].includes(role)
}

// FASE 03B.1: visão financeira AGREGADA (tela Financeiro, /api/finance, cards do dashboard).
// Somente OWNER e MANAGER — o mesmo que private.is_org_manager no banco, que é a autoridade final.
// Não muda as permissões financeiras individuais da reserva (painel da reserva / 03A).
export const FINANCE_VIEW_ROLES = [ROLES.OWNER, ROLES.MANAGER]
export function canViewFinance(role) {
  return FINANCE_VIEW_ROLES.includes(role)
}

export function isOwnerOrAbove(role) {
  return [ROLES.PLATFORM_SUPER_ADMIN, ROLES.OWNER].includes(role)
}

export const ROLE_LABELS = {
  PLATFORM_SUPER_ADMIN: 'Administrador da Plataforma',
  OWNER: 'Proprietário',
  MANAGER: 'Gerente',
  RECEPTIONIST: 'Recepção',
}
