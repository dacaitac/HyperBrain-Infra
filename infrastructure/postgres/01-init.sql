-- Runs once on first PG startup (docker-entrypoint-initdb.d)
-- Idempotent: IF NOT EXISTS guards prevent re-run failures

-- pgvector extension (ADR-003)
CREATE EXTENSION IF NOT EXISTS vector;

-- Auth schema for GoTrue (Supabase)
CREATE SCHEMA IF NOT EXISTS auth;

-- Roles required by PostgREST (ADR: Supabase minimal profile)
-- Full grants are applied by DDL migrations (S0-02)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
