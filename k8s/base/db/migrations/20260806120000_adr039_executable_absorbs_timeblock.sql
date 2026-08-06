-- ADR-039 (#25): the executable absorbs the time block. TIME_BLOCK becomes a first-class
-- core_executable type and containment collapses onto the executable row itself; the ADR-027
-- bridge (core_time_block / core_time_block_member) is FROZEN as imputation history.
--
-- This migration does six things:
--   1. core_executable.type          -- admits 'TIME_BLOCK' (CHECK widened, name reused).
--   2. Six additive columns          -- origin / actual_duration_minutes (block payload absorbed),
--                                       container_block_id / container_planned_minutes /
--                                       container_ord (containment absorbed from the bridge),
--                                       imputed_block_id (successor of imputed_time_block_id,
--                                       which stays frozen pointing at legacy history).
--   3. Pre-flights                   -- (a) FAIL LOUDLY if any core_time_block.id collides with a
--                                       pre-existing core_executable.id (id-preserving backfill
--                                       would be impossible); (b) REPORT (notice, not error)
--                                       members sitting in more than one live block.
--   4. Backfill of LIVE blocks       -- every PLANNED/ACTIVE core_time_block becomes a
--                                       core_executable row with the SAME UUID (rule #15, bug #15:
--                                       regenerating ids would break sync_mapping and duplicate
--                                       EKEvents on write-back). SETTLED/EXPIRED blocks are NOT
--                                       migrated: they are history and stay in the frozen bridge.
--   5. Backfill of containment       -- each member of a live block gets container_block_id
--                                       pointed at its nearest live block (MIN date_start when in
--                                       several), plus the member's planned_minutes and ord.
--   6. Freeze of the legacy bridge   -- COMMENT ON both tables, DROP of the ADR-027 derivation
--                                       triggers and of the D5 unique index. D5 ("<= 1 block per
--                                       executable") is now STRUCTURAL: container_block_id is a
--                                       scalar column, an executable can sit in at most one
--                                       container by construction; the per-day flavor becomes
--                                       planner business logic, not schema. NO table/column is
--                                       dropped (additive MVP rule).
--
-- IDENTITY IS PRESERVED (critical, rule #15): the backfill inserts core_time_block.id VERBATIM as
-- the new core_executable.id. No id is regenerated anywhere in this file.
--
-- imputed_block_id gets NO backfill on purpose: imputation happens at settlement (DR-08), so every
-- existing imputed_time_block_id points at a SETTLED legacy block — exactly the history that stays
-- frozen in the bridge. New settlements write imputed_block_id against TIME_BLOCK executables.
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically with the
-- migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Reviewed by Daniel BEFORE it reaches prod (never `supabase db push` from the AI, never applied
-- to prod by the AI). Tested locally against a throwaway container built from these migrations.
--
-- Idempotent / re-runnable: DROP CONSTRAINT IF EXISTS + ADD (name reused), ADD COLUMN IF NOT
-- EXISTS, CREATE INDEX IF NOT EXISTS, an ON CONFLICT DO NOTHING backfill, a containment UPDATE
-- guarded by container_block_id IS NULL and DROP ... IF EXISTS make a second application a no-op;
-- pre-flight (a) explicitly excludes the TIME_BLOCK rows created by a previous run. The ledger
-- also prevents re-application on an already-migrated cluster.
--
-- Additive only (MVP rule): no DROP TABLE / DROP COLUMN. The dropped triggers and index are the
-- ADR-027 derivation MACHINERY of a bridge that stops receiving writes — not data. Their plpgsql
-- functions are deliberately NOT dropped (harmless orphans; they keep the rollback below exact).
--
-- Rollback path (manual, only meaningful before `core` starts writing TIME_BLOCK rows):
--   UPDATE core_executable SET container_block_id = NULL, container_planned_minutes = NULL,
--                              container_ord = NULL, imputed_block_id = NULL
--    WHERE container_block_id IS NOT NULL OR imputed_block_id IS NOT NULL;
--   DELETE FROM core_executable WHERE type = 'TIME_BLOCK';
--   -- restore the previous CHECK (list without 'TIME_BLOCK'), drop the six columns and the two
--   -- indexes, recreate the ADR-027 triggers + uq_core_time_block_member_executable_day (their
--   -- functions still exist). The legacy bridge itself is INTACT — this file never modifies a
--   -- single row of core_time_block or core_time_block_member — so nothing else to restore.
--
-- Mirror note (S0-07, core#58): HyperBrain-core/src/main/resources/db/migration/V1__init.sql
-- mirrors this EXACT shape in the same unit of work — the core reads/writes TIME_BLOCK rows and
-- the containment columns via JDBC/JPA, so Testcontainers (ddl-auto: validate) MUST know about
-- them. Keep the two in lockstep.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 — core_executable.type admits 'TIME_BLOCK'.
-- type is TEXT + CHECK (not a PG enum): no ALTER TYPE hazard. Dropping and re-adding the SAME
-- constraint name inside the single transaction is atomic and lock-cheap. Existing values
-- preserved ('BUYING' included since ADR-037/#23), 'TIME_BLOCK' appended.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_executable DROP CONSTRAINT IF EXISTS core_executable_type_check;
ALTER TABLE public.core_executable
    ADD CONSTRAINT core_executable_type_check
    CHECK (type IN ('TASK', 'HABIT', 'LEAD_MEASURE', 'ACTIVITY', 'AGENDA',
                    'LEARNING_SESSION', 'BUYING', 'TIME_BLOCK'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 — The absorbed columns. All nullable, no defaults: metadata-only changes in PostgreSQL
-- (no table rewrite, no lock on existing rows); non-TIME_BLOCK rows simply read NULL.
--
-- origin                    -- who placed the block (mirrors legacy core_time_block.origin;
--                              nullable here because only TIME_BLOCK rows carry it).
-- actual_duration_minutes   -- settlement accounting (mirrors the legacy column).
-- container_block_id        -- the executable's ONE container (a TIME_BLOCK executable).
--                              ON DELETE SET NULL: deleting a block frees its members.
-- container_planned_minutes -- the member's share of the container's time (ADR-027 semantics).
-- container_ord             -- the member's order inside the container (LLM fine sequencing).
-- imputed_block_id          -- block the completed subtask was imputed to on settlement (DR-08),
--                              successor of imputed_time_block_id which stays frozen on legacy.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_executable
    ADD COLUMN IF NOT EXISTS origin TEXT
        CHECK (origin IS NULL OR origin IN ('PLANNER', 'FOCUS', 'USER')),
    ADD COLUMN IF NOT EXISTS actual_duration_minutes INTEGER,
    ADD COLUMN IF NOT EXISTS container_block_id UUID
        REFERENCES public.core_executable (id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS container_planned_minutes INTEGER
        CHECK (container_planned_minutes IS NULL OR container_planned_minutes >= 0),
    ADD COLUMN IF NOT EXISTS container_ord INTEGER
        CHECK (container_ord IS NULL OR container_ord >= 0),
    ADD COLUMN IF NOT EXISTS imputed_block_id UUID
        REFERENCES public.core_executable (id) ON DELETE SET NULL;

-- Lookup indexes: "who are this block's members" and "what was imputed to this block".
-- (idx_core_executable_imputed_block already serves the FROZEN legacy column.)
CREATE INDEX IF NOT EXISTS idx_core_executable_container_block
    ON public.core_executable (container_block_id);
CREATE INDEX IF NOT EXISTS idx_core_executable_imputed_block_id
    ON public.core_executable (imputed_block_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3a — Pre-flight: id-preserving backfill requires ZERO collisions between core_time_block ids
-- and pre-existing core_executable ids. Both default to gen_random_uuid() so a collision is
-- cosmically unlikely — but if one exists, ON CONFLICT DO NOTHING would SILENTLY skip that block
-- and containment would point members at a random unrelated executable. Fail loudly instead;
-- remediation is a human decision. TIME_BLOCK rows are excluded: they are this migration's own
-- output on a previous run (idempotent re-application), not a collision.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_colliding TEXT;
BEGIN
    SELECT string_agg(format('%s (block %s vs executable type %s)', b.id, b.status, e.type), '; ')
      INTO v_colliding
      FROM public.core_time_block b
      JOIN public.core_executable e ON e.id = b.id
     WHERE e.type <> 'TIME_BLOCK';

    IF v_colliding IS NOT NULL THEN
        RAISE EXCEPTION
            'ADR-039 pre-flight failed: core_time_block id(s) collide with pre-existing core_executable id(s) — id-preserving backfill (rule #15) impossible: %',
            v_colliding;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3b — Pre-flight REPORT (not an error): members sitting in more than one LIVE block.
-- The ADR-027 D5 index only forbade two live blocks per executable per DAY, so an executable
-- planned into live blocks on different days is legitimate legacy data. The scalar
-- container_block_id can hold only ONE of them: the backfill below deterministically keeps the
-- nearest live block (MIN date_start, block id as tie-break) and this notice lists every
-- affected executable so Daniel can eyeball the choice during review.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_multi TEXT;
BEGIN
    SELECT string_agg(
               format('executable %s is in %s live blocks (containment keeps block %s @ %s)',
                      d.executable_id, d.n, d.kept_block_id, d.kept_date_start),
               '; ')
      INTO v_multi
      FROM (
          SELECT m.executable_id,
                 count(*) AS n,
                 (array_agg(m.block_id ORDER BY b.date_start, m.block_id))[1] AS kept_block_id,
                 min(b.date_start) AS kept_date_start
            FROM public.core_time_block_member m
            JOIN public.core_time_block b ON b.id = m.block_id
           WHERE b.status IN ('PLANNED', 'ACTIVE')
           GROUP BY m.executable_id
          HAVING count(*) > 1
      ) d;

    IF v_multi IS NOT NULL THEN
        RAISE NOTICE
            'ADR-039 pre-flight report: members with more than one live block (resolved to nearest): %',
            v_multi;
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4 — Backfill of LIVE blocks (id-preserving). One core_executable row per PLANNED/ACTIVE
-- core_time_block, SAME UUID. Field mapping:
--   user_id  -> first member's owner (ord, then id, deterministic), else the legacy 1:1 anchor's
--               owner, else the MVP system user (single-user MVP seed).
--   name     -> theme (ADR-027 D1), else the legacy anchor's name, else 'Time Block'.
--   status   -> PLANNED stays PLANNED; ACTIVE maps to IN_PROGRESS (both already in the CHECK).
--               No ELSE branch: an unexpected status violates NOT NULL and aborts — fail loudly.
--   system_generated = false: blocks are plan, not DR-06 snapshot machinery.
-- SETTLED/EXPIRED blocks are intentionally NOT selected: frozen history in the legacy bridge.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.core_executable
    (id, user_id, type, name, description, status,
     start_time, end_time, origin, actual_duration_minutes,
     system_generated, created_at)
SELECT b.id,
       COALESCE(
           (SELECT me.user_id
              FROM public.core_time_block_member m
              JOIN public.core_executable me ON me.id = m.executable_id
             WHERE m.block_id = b.id
             ORDER BY m.ord, m.executable_id
             LIMIT 1),
           anchor.user_id,
           '00000000-0000-0000-0000-000000000001'::uuid),
       'TIME_BLOCK',
       COALESCE(b.theme, anchor.name, 'Time Block'),
       b.reason,
       CASE b.status
           WHEN 'PLANNED' THEN 'PLANNED'
           WHEN 'ACTIVE'  THEN 'IN_PROGRESS'
       END,
       b.date_start,
       b.date_end,
       b.origin,
       b.actual_duration_minutes,
       false,
       b.created_at
  FROM public.core_time_block b
  LEFT JOIN public.core_executable anchor ON anchor.id = b.executable_id
 WHERE b.status IN ('PLANNED', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5 — Backfill of containment. Every member of a live block points at its nearest live block
-- (same deterministic order as the 3b report). Guarded by container_block_id IS NULL: a re-run
-- (or a member the core already re-parented) is never overwritten from frozen legacy data.
-- The FK holds because step 4 created a TIME_BLOCK executable with that exact UUID.
-- ─────────────────────────────────────────────────────────────────────────────
WITH nearest_live AS (
    SELECT DISTINCT ON (m.executable_id)
           m.executable_id,
           m.block_id,
           m.planned_minutes,
           m.ord
      FROM public.core_time_block_member m
      JOIN public.core_time_block b ON b.id = m.block_id
     WHERE b.status IN ('PLANNED', 'ACTIVE')
     ORDER BY m.executable_id, b.date_start, m.block_id
)
UPDATE public.core_executable e
   SET container_block_id        = nl.block_id,
       container_planned_minutes = nl.planned_minutes,
       container_ord             = nl.ord
  FROM nearest_live nl
 WHERE e.id = nl.executable_id
   AND e.container_block_id IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6 — Freeze the legacy bridge. The tables SURVIVE untouched (additive MVP rule) as imputation
-- history — imputed_time_block_id keeps resolving against them — but nothing writes to them
-- anymore: the ADR-027 derivation triggers and the D5 unique index are retired. D5 is now
-- structural in core_executable.container_block_id (a scalar can hold one container, period).
-- ─────────────────────────────────────────────────────────────────────────────
COMMENT ON TABLE public.core_time_block IS
    'Frozen legacy (ADR-039): imputation history only — no writes. Live blocks were copied id-preserving into core_executable (type = TIME_BLOCK).';
COMMENT ON TABLE public.core_time_block_member IS
    'Frozen legacy (ADR-039): imputation history only — no writes. Live containment moved to core_executable.container_block_id.';

DROP TRIGGER IF EXISTS trg_core_time_block_propagate_members ON public.core_time_block;
DROP TRIGGER IF EXISTS trg_core_time_block_member_derive ON public.core_time_block_member;
DROP INDEX IF EXISTS public.uq_core_time_block_member_executable_day;
