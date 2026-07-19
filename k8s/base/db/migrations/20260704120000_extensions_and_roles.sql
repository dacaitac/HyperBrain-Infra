-- DDL v1 — Bootstrap: extensions and PostgREST roles (ERD v2.0.0, S0-02)
-- Self-contained so `supabase db reset` provisions everything the domain
-- migrations depend on, even when the Compose bootstrap (01-init.sql) is absent.
-- Idempotent: safe to re-run.

-- pgvector for RAG embeddings (ADR-003)
CREATE EXTENSION IF NOT EXISTS vector;

-- Auth schema consumed by GoTrue (Supabase minimal profile)
CREATE SCHEMA IF NOT EXISTS auth;

-- Roles required by PostgREST
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
