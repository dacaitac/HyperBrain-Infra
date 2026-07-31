-- ADR-037: BUYING joins core_executable.type — a dateless shopping-item reminder that the Core
-- write-back gathers in a dedicated "Compras" Reminders list (SentinelAPI resolve-or-creates it).
-- A type transition into/out of BUYING re-targets the reminder's list (moved on update).
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically with the
-- migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Reviewed by Daniel BEFORE it reaches prod (never `supabase db push` from the AI, never applied
-- to prod by the AI). Tested locally against a throwaway container built from these migrations.
--
-- Idempotent / re-runnable: DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT (name reused) make a
-- second application a no-op; the ledger also prevents re-application on a migrated cluster.
--
-- Additive only (MVP rule): no DROP TABLE/COLUMN, no table rewrite, no backfill (no row is BUYING
-- yet — existing rows all satisfy the widened CHECK).
--
-- Mirror note (S0-07): HyperBrain-core/src/main/resources/db/migration/V1__init.sql is updated in
-- the SAME unit of work — the core reads/writes core_executable.type='BUYING' via JDBC/JPA, so
-- Testcontainers (ddl-auto: validate) MUST know about it. Keep the two in lockstep.

-- ─────────────────────────────────────────────────────────────────────────────
-- Extend the core_executable.type CHECK to admit 'BUYING'.
-- type is TEXT + CHECK (not a PG enum): no ALTER TYPE hazard. Dropping and re-adding the SAME
-- constraint name inside the single transaction is atomic and lock-cheap (a validate scan of a
-- small table). Existing values preserved, 'BUYING' appended.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_executable DROP CONSTRAINT IF EXISTS core_executable_type_check;
ALTER TABLE public.core_executable
    ADD CONSTRAINT core_executable_type_check
    CHECK (type IN ('TASK', 'HABIT', 'LEAD_MEASURE', 'ACTIVITY', 'AGENDA',
                    'LEARNING_SESSION', 'BUYING'));
