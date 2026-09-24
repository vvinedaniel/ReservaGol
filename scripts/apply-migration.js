// Applies /app/supabase/migration.sql to a Postgres/Supabase database.
// Usage: DATABASE_URL='postgresql://...' node scripts/apply-migration.js
const fs = require('fs')
const path = require('path')
const { Client } = require('pg')

async function main() {
  const url = process.env.DATABASE_URL
  if (!url) { console.error('Missing DATABASE_URL'); process.exit(1) }
  const sql = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'migration.sql'), 'utf8')
  const client = new Client({ connectionString: url, ssl: { rejectUnauthorized: false } })
  try {
    await client.connect()
    console.log('Connected. Applying migration...')
    await client.query(sql)
    console.log('Migration applied successfully.')
  } catch (e) {
    console.error('Migration failed:', e.message)
    process.exit(1)
  } finally {
    await client.end()
  }
}
main()
