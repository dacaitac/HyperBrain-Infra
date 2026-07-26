-- ADR-027 (#18): the time block stops being 1:1 with an executable and becomes a
-- themed TIME CONTAINER that references N executables through a bridge table.
--
-- This migration does five things:
--   1. core_time_block.theme        -- the block's name (LLM-generated, ADR-029; nullable
--                                      because the deterministic floor may leave it derived).
--   2. core_cycle.description       -- the commitment's "why", consumed as prompt context by
--                                      the agenda LLM (ADR-029 v2.1.0, docs#80). The ERD and
--                                      Notion's `Description` property already assumed this
--                                      column; the table never had it, so Notion's Description
--                                      synced to nothing. Creating it closes that ERD<->DB<->
--                                      Notion inconsistency.
--   3. core_time_block_member       -- the bridge table (ADR-027 D2): block -> N executables
--                                      with per-member planned_minutes and ord.
--   4. The D5 invariant             -- <= 1 block per executable per day, enforced by a real
--                                      unique index (see "D5" below for the design rationale).
--   5. Backfill 1:1 -> N            -- one member row per live block, PRESERVING every existing
--                                      core_time_block.id.
--
-- IDENTITY IS PRESERVED (critical, bug #15): this migration never writes core_time_block.id.
-- Regenerating block ids would break the sync_mapping of each block and make the write-back
-- emit CREATE instead of UPDATE, duplicating EKEvents in Apple on every replan.
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically with the
-- migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Reviewed by Daniel BEFORE it reaches prod (never `supabase db push` from the AI, never applied
-- to prod by the AI). Tested locally against a throwaway container built from these migrations.
--
-- Idempotent / re-runnable: ADD COLUMN IF NOT EXISTS + CREATE ... IF NOT EXISTS + CREATE OR
-- REPLACE FUNCTION + DROP TRIGGER IF EXISTS + an ON CONFLICT DO NOTHING backfill make a second
-- application a no-op; the ledger also prevents re-application on an already-migrated cluster.
--
-- Additive only (MVP rule): no DROP, no non-additive change. core_time_block.executable_id
-- SURVIVES as the legacy 1:1 pointer — the core keeps writing it during the transition, and
-- EXPIRED blocks (which get no member row, see the backfill) keep their history through it.
-- Retiring that column is a separate, non-additive step once `core` no longer reads it.
--
-- Rollback path (manual, only meaningful before `core` starts writing memberships):
--   DROP TRIGGER trg_core_time_block_propagate_members ON core_time_block;
--   DROP TRIGGER trg_core_time_block_member_derive ON core_time_block_member;
--   DROP FUNCTION core_time_block_propagate_to_members(); DROP FUNCTION core_time_block_member_derive();
--   DROP TABLE core_time_block_member;   -- drops the D5 index with it
--   ALTER TABLE core_time_block DROP COLUMN theme; ALTER TABLE core_cycle DROP COLUMN description;
-- No existing data is touched by this migration, so the rollback loses only the memberships
-- created after it (and any theme/description written since).
--
-- Mirror note (S0-07): HyperBrain-core/src/main/resources/db/migration/V1__init.sql is updated
-- in the SAME unit of work — the core reads/writes core_time_block_member, core_time_block.theme
-- and core_cycle.description via JDBC/JPA, so Testcontainers (ddl-auto: validate) MUST know
-- about them. Keep the two in lockstep.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 — core_time_block.theme (ADR-027 D1)
-- Nullable, no default: a metadata-only change in PostgreSQL (no table rewrite, no lock on
-- existing rows). Every existing block simply reads NULL until a themed plan replaces it.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_time_block
    ADD COLUMN IF NOT EXISTS theme TEXT;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 — core_cycle.description (ADR-029 v2.1.0, docs#80)
-- Same shape and same reasoning: nullable, no default, metadata-only.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_cycle
    ADD COLUMN IF NOT EXISTS description TEXT;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3 — core_time_block_member: the bridge table (ADR-027 D2)
--
-- planned_minutes  -- the member's share of the container's time (fine-grained counterpart of
--                     the ADR-013 imputation accounting).
-- ord              -- the member's order inside the theme (the LLM's fine sequencing, ADR-019).
--
-- block_date / block_status are DERIVED, TRIGGER-OWNED columns, never written by the core: they
-- exist only to make the D5 invariant enforceable by an index (see below). They are copies of
-- core_time_block.date_start (as the owner's local day) and core_time_block.status.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.core_time_block_member (
    block_id        UUID    NOT NULL REFERENCES public.core_time_block (id) ON DELETE CASCADE,
    executable_id   UUID    NOT NULL REFERENCES public.core_executable (id) ON DELETE CASCADE,
    planned_minutes INTEGER NOT NULL CHECK (planned_minutes >= 0),
    ord             INTEGER NOT NULL CHECK (ord >= 0),
    -- derived (trigger-maintained) — the D5 enforcement surface
    block_date      DATE    NOT NULL,
    block_status    TEXT    NOT NULL
                        CHECK (block_status IN ('PLANNED', 'ACTIVE', 'SETTLED', 'EXPIRED')),
    PRIMARY KEY (block_id, executable_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- D5 — "<= 1 block per executable per day", enforced structurally.
--
-- WHY DENORMALIZE THE DAY. The day of a membership lives in the PARENT row
-- (core_time_block.date_start), and PostgreSQL cannot build a unique index over a join, nor a
-- GENERATED column over another table — and not even over `date_start AT TIME ZONE <tz>`, since
-- that expression is STABLE (tz database dependent), not IMMUTABLE. The only way to get a REAL
-- unique index (what ADR-027 D5 asks for, as opposed to an advisory check) is to carry the day
-- down into the bridge row. It is written by a trigger, so it cannot drift and the core never
-- has to know about it.
--
-- WHY THE INDEX IS PARTIAL. EXPIRED blocks are out of the plan: TimeBlockExpiryScheduler marks a
-- missed block EXPIRED, and the Planner's walls (JdbcPlannerStateRepository.OCCUPIED_BLOCKS_SQL)
-- deliberately consider only PLANNED/ACTIVE/SETTLED. A same-day replan (HU-02) legitimately
-- re-places that executable into a NEW block, so an unconditional unique index would make the
-- replan fail with a constraint violation. The predicate is exactly the "live block" set the
-- backfill below uses.
--
-- CONSEQUENCE FOR `core`: an insert that would place an executable in a second live block of the
-- same day now RAISES. That is the invariant doing its job — the caller (planner) must either
-- reuse the existing block (stable identity, ADR-027 D3) or handle the conflict explicitly
-- (ON CONFLICT), never regenerate ids.
-- ─────────────────────────────────────────────────────────────────────────────

-- Derivation on the member side: fires on INSERT and whenever the row is re-pointed at another
-- block/executable. The owner's timezone comes from sys_user through the MEMBER's executable
-- (not through the legacy core_time_block.executable_id, which is on its way out).
CREATE OR REPLACE FUNCTION public.core_time_block_member_derive()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS $$
DECLARE
    v_date_start TIMESTAMPTZ;
    v_status     TEXT;
    v_timezone   TEXT;
BEGIN
    SELECT b.date_start, b.status
      INTO v_date_start, v_status
      FROM public.core_time_block b
     WHERE b.id = NEW.block_id;

    IF v_date_start IS NULL THEN
        RAISE EXCEPTION 'core_time_block_member: block % has no date_start', NEW.block_id;
    END IF;

    SELECT COALESCE(u.timezone, 'America/Bogota')
      INTO v_timezone
      FROM public.core_executable e
      JOIN public.sys_user u ON u.id = e.user_id
     WHERE e.id = NEW.executable_id;

    NEW.block_date   := (v_date_start AT TIME ZONE COALESCE(v_timezone, 'America/Bogota'))::date;
    NEW.block_status := v_status;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_core_time_block_member_derive ON public.core_time_block_member;
CREATE TRIGGER trg_core_time_block_member_derive
    BEFORE INSERT OR UPDATE OF block_id, executable_id
    ON public.core_time_block_member
    FOR EACH ROW
EXECUTE FUNCTION public.core_time_block_member_derive();

-- Propagation on the block side: moving a block to another day, or changing its lifecycle
-- status, refreshes its members. A move that would collide with another live block of the same
-- executable on the target day fails here, on the unique index — by design.
CREATE OR REPLACE FUNCTION public.core_time_block_propagate_to_members()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.core_time_block_member m
       SET block_status = NEW.status,
           block_date   = (NEW.date_start AT TIME ZONE COALESCE(u.timezone, 'America/Bogota'))::date
      FROM public.core_executable e
      JOIN public.sys_user u ON u.id = e.user_id
     WHERE m.block_id = NEW.id
       AND e.id = m.executable_id;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_core_time_block_propagate_members ON public.core_time_block;
CREATE TRIGGER trg_core_time_block_propagate_members
    AFTER UPDATE OF date_start, status
    ON public.core_time_block
    FOR EACH ROW
    WHEN (OLD.date_start IS DISTINCT FROM NEW.date_start
          OR OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION public.core_time_block_propagate_to_members();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4 — Pre-flight: refuse to migrate data that already violates D5.
-- If production somehow holds two live blocks for the same executable on the same local day, the
-- backfill (and the unique index below) cannot both succeed and be honest. Fail loudly, with the
-- offending pairs listed, instead of silently dropping a membership and leaving an empty block.
-- Remediation is a human decision: EXPIRE or delete the redundant block, then re-run.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_offenders TEXT;
BEGIN
    SELECT string_agg(format('executable %s on %s (%s blocks)', d.executable_id, d.day, d.n), '; ')
      INTO v_offenders
      FROM (
          SELECT b.executable_id,
                 (b.date_start AT TIME ZONE COALESCE(u.timezone, 'America/Bogota'))::date AS day,
                 count(*) AS n
            FROM public.core_time_block b
            JOIN public.core_executable e ON e.id = b.executable_id
            JOIN public.sys_user u        ON u.id = e.user_id
           WHERE b.status IN ('PLANNED', 'ACTIVE', 'SETTLED')
           GROUP BY 1, 2
          HAVING count(*) > 1
      ) d;

    IF v_offenders IS NOT NULL THEN
        RAISE EXCEPTION
            'ADR-027 D5 pre-flight failed: existing data already has >1 live block per executable per day: %',
            v_offenders;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5 — Backfill 1:1 -> N. One member row per LIVE block (PLANNED/ACTIVE/SETTLED), carrying the
-- block's current executable_id. EXPIRED blocks are intentionally left without members: they are
-- history, not plan, and the D5 index excludes them anyway (their legacy executable_id keeps the
-- record). planned_minutes falls back to the block's wall-clock duration, then to 0, because the
-- column is NOT NULL and planned_minutes is nullable on core_time_block.
-- block_date / block_status are filled by the trigger above — never by this INSERT.
-- No core_time_block.id is written anywhere in this file (bug #15).
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.core_time_block_member (block_id, executable_id, planned_minutes, ord)
SELECT b.id,
       b.executable_id,
       COALESCE(
           b.planned_minutes,
           CASE
               WHEN b.date_end IS NOT NULL
                   THEN GREATEST(0, (EXTRACT(EPOCH FROM (b.date_end - b.date_start)) / 60)::int)
           END,
           0),
       0
  FROM public.core_time_block b
 WHERE b.status IN ('PLANNED', 'ACTIVE', 'SETTLED')
ON CONFLICT (block_id, executable_id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6 — The D5 unique index itself (created after the backfill so a pre-existing violation is
-- reported by the pre-flight above, with a readable message, rather than as a raw index error).
-- Plain CREATE INDEX, not CONCURRENTLY: the migration runner wraps every file in
-- --single-transaction (apply-migrations.sh) and the table is empty-to-tiny at MVP scale.
-- It doubles as the lookup index "which block holds this executable today".
-- ─────────────────────────────────────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uq_core_time_block_member_executable_day
    ON public.core_time_block_member (executable_id, block_date)
    WHERE block_status IN ('PLANNED', 'ACTIVE', 'SETTLED');
