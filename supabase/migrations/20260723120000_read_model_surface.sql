-- ADR-025 (#15): read-model surface for Supabase / PostgREST — the `api` schema of
-- security_invoker views is the ONLY surface PostgREST exposes; the CRUD hole on
-- `public` (JWT `authenticated` could write core_executable/outbox/sync directly,
-- bypassing the whole domain pipeline) is closed structurally by grants (D2).
--
-- This migration does four things, all part of one decision (D1..D8):
--   1. Creates schema `api` and the four honest read-model views (D1/D3/D6/D7).
--   2. Creates the narrow persisted projection `plnr_daily_rollup` (D4) that the
--      core's DailyAdherenceRollupService upserts (single-sourcing the adherence
--      formula in AdherenceCalculator instead of reimplementing it in SQL).
--   3. Revokes INSERT/UPDATE/DELETE from `authenticated` on `public` and corrects
--      the ALTER DEFAULT PRIVILEGES of 20260704120700_postgrest_grants.sql so future
--      tables never inherit write privileges (D2 — the core of the ADR).
--   4. Adds two forward-looking indexes (D8).
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically
-- with the migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Applied by hand via psql after human review (never `supabase db push`); see
-- reference: migrations run manually on daniel-ubuntu. NOT applied to prod by the AI.
--
-- Idempotent / re-runnable: CREATE ... IF NOT EXISTS + CREATE OR REPLACE VIEW make a
-- second application a no-op; the ledger also prevents re-application on an
-- already-migrated cluster.
--
-- Mirror notes (S0-07): HyperBrain-core/src/main/resources/db/migration/V1__init.sql
-- is updated in the same unit of work by core-engineer — but ONLY for
-- `plnr_daily_rollup`, because the core reads/writes it via JDBC. The `api` views are
-- NOT mirrored into Flyway: they are consumed by the iOS app, never by the core, so
-- Testcontainers (JPA `ddl-auto: validate`) has no reason to know about them.

-- ─────────────────────────────────────────────────────────────────────────────
-- D1 — dedicated `api` schema (read-only views only; PostgREST points here)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS api;
GRANT USAGE ON SCHEMA api TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- D2 — correct the DEFAULT PRIVILEGES *before* creating any object, so every table
-- created from here on (including plnr_daily_rollup below) inherits only SELECT for
-- `authenticated`, never write. This ALTER runs as the same role (`hyperbrain`) that
-- issued the original GRANT in 20260704120700, so it cancels that grant's write
-- portion for future objects while keeping SELECT.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE INSERT, UPDATE, DELETE ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA api
    GRANT SELECT ON TABLES TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- D4 — plnr_daily_rollup: narrow persisted projection of DailyAdherenceReport.
-- Columns map the record's persisted measures 1:1 (date -> agenda_date is the PK;
-- `zone` is NOT stored — it is only the context used to derive the local day, and
-- the user's timezone already lives in sys_user.timezone). `ritual_completed` is the
-- record's boxed `Boolean` (a partial proxy for the ADR-018 ritual, per its Javadoc),
-- so it is the one measure column that is nullable; every other measure is a Java
-- primitive and is therefore NOT NULL. Enmienda acotada a ADR-016 (proyección
-- persistida junto al log raw-first).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.plnr_daily_rollup (
    user_id           UUID             NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    agenda_date       DATE             NOT NULL,
    blocks_planned    INTEGER          NOT NULL,
    blocks_executed   INTEGER          NOT NULL,
    adherence         DOUBLE PRECISION NOT NULL,
    wig_hit           BOOLEAN          NOT NULL,
    ritual_completed  BOOLEAN,
    replan_count      INTEGER          NOT NULL,
    abandoned         BOOLEAN          NOT NULL,
    materialized_at   TIMESTAMPTZ      NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, agenda_date)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- D3/D6 — read-model views. ALL are `security_invoker = true` (PG16): they execute
-- with the INVOKER's privileges (`authenticated`), not the owner's — coherent with
-- the D2 grant policy. Columns are named in the surface's own vocabulary (anti-
-- corruption layer, D7): the write schema can evolve behind them.
-- ─────────────────────────────────────────────────────────────────────────────

-- Ranked executables the user can still act on. `is_stale` (D6) is derived from the
-- raw `priority_computed_at` with the tunable 24h threshold; is_stale = true is the
-- expected default until the refresh tick (#68) exists, NOT a bug.
CREATE OR REPLACE VIEW api.v_task_priority
    WITH (security_invoker = true) AS
SELECT
    e.user_id,
    e.id                  AS executable_id,
    e.name,
    e.type,
    e.status,
    e.priority_score,
    e.urgency_score,
    e.effort_score,
    e.progress,
    e.priority_computed_at,
    (e.priority_computed_at IS NULL
        OR e.priority_computed_at < now() - interval '24 hours') AS is_stale,
    ep.impact
FROM public.core_executable e
LEFT JOIN public.core_execution_profile ep ON ep.executable_id = e.id
WHERE e.status NOT IN ('DONE', 'FAILED')
  AND e.type IN ('TASK', 'HABIT', 'LEARNING_SESSION', 'LEAD_MEASURE');

-- Agenda blocks. core_time_block has NO user_id, so the JOIN through core_executable
-- to sys_user is obligatory (D3) both to derive the owner and to read the timezone.
-- `agenda_date` is the block's LOCAL day in the user's timezone. The view does NOT
-- embed now(): the app filters the day (keeps the view pure and cacheable).
CREATE OR REPLACE VIEW api.v_agenda_block
    WITH (security_invoker = true) AS
SELECT
    e.user_id,
    (tb.date_start AT TIME ZONE u.timezone)::date AS agenda_date,
    tb.id                        AS block_id,
    tb.executable_id,
    e.name,
    e.type,
    tb.date_start,
    tb.date_end,
    tb.status,
    tb.origin,
    tb.planned_minutes,
    tb.actual_duration_minutes,
    tb.reason
FROM public.core_time_block tb
JOIN public.core_executable e ON e.id = tb.executable_id
JOIN public.sys_user u        ON u.id = e.user_id;

-- Per-cycle progress by flat count (D3). Filters by status = 'ACTIVE' and NOT by type,
-- because the ADR-015 migration (CORE_CYCLE absorbs CORE_PROJECT) is not yet applied
-- in prod — filtering by type would break against the real production schema.
CREATE OR REPLACE VIEW api.v_cycle_progress
    WITH (security_invoker = true) AS
SELECT
    c.user_id,
    c.id    AS cycle_id,
    c.name,
    c.type,
    c.status,
    count(e.id)                                        AS total_executables,
    count(e.id) FILTER (WHERE e.status = 'DONE')       AS done_executables,
    (count(e.id) FILTER (WHERE e.status = 'DONE'))::float
        / NULLIF(count(e.id), 0)                       AS completion_ratio
FROM public.core_cycle c
LEFT JOIN public.core_executable e ON e.cycle_id = c.id
WHERE c.status = 'ACTIVE'
GROUP BY c.user_id, c.id, c.name, c.type, c.status;

-- Daily adherence: straight pass-through of the persisted rollup (D4). The formula
-- lives once in AdherenceCalculator; SQL never recomputes it.
CREATE OR REPLACE VIEW api.v_daily_adherence
    WITH (security_invoker = true) AS
SELECT * FROM public.plnr_daily_rollup;

-- ─────────────────────────────────────────────────────────────────────────────
-- D8 — forward-looking indexes.
-- Deviation from the ADR: D8 specifies CREATE INDEX CONCURRENTLY, but CONCURRENTLY
-- cannot run inside a transaction and the migration runner wraps every file in
-- --single-transaction (apply-migrations.sh). At MVP scale the plain-index lock is
-- trivial (both tables are tiny; the Data Scientist confirmed sub-millisecond seq
-- scans — these indexes are forward-looking to multiuser), so a plain CREATE INDEX
-- is the correct trade-off here. IF NOT EXISTS keeps it re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_core_time_block_date_start
    ON public.core_time_block (date_start);
CREATE INDEX IF NOT EXISTS idx_core_executable_user_priority
    ON public.core_executable (user_id, priority_score DESC NULLS LAST);

-- ─────────────────────────────────────────────────────────────────────────────
-- D2 (grants, the core of the ADR) — impose read-models-only structurally.
--
-- Revoke every write privilege from `authenticated` on existing public tables. This
-- covers plnr_daily_rollup too: only the core (JDBC, as owner `hyperbrain`) writes it.
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM authenticated;

-- SUBTLE INVARIANT — do NOT revoke SELECT on public here. The `api` views are
-- security_invoker, so they execute with the caller's (`authenticated`) privileges;
-- if `authenticated` lost SELECT on the underlying public tables, every view would
-- fail at runtime with "permission denied". The closure of *direct* reads is provided
-- by PGRST_DB_SCHEMA=api (PostgREST only ever exposes `api`, never `public`), NOT by
-- revoking this SELECT. Keeping SELECT on public is what makes the views work.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;

-- The `api` views (views count as tables for GRANT) are the whole read surface.
GRANT SELECT ON ALL TABLES IN SCHEMA api TO authenticated;
