-- ADR-015 — CORE_CYCLE absorbs CORE_PROJECT and gains a free-form hierarchy.
--
-- Forward migration over the existing production schema (applied via psql; see
-- reference: migrations run by hand on daniel-ubuntu). Data-preserving: every
-- core_project row is promoted to a core_cycle of type PROJECT (id preserved),
-- and the project_id FKs are repointed to cycle_id before the columns/table drop.
--
-- Idempotent / re-runnable: the data-dependent backfill is guarded by the
-- existence of core_project, and every DDL step uses IF [NOT] EXISTS, so a second
-- application (e.g. a later `supabase db push` that never tracked the hand-applied
-- run) is a no-op instead of an error. The whole migration is transactional.

BEGIN;

-- 1. Expand the cycle type enum (horizon ladder + absorbed PROJECT).
ALTER TABLE core_cycle DROP CONSTRAINT IF EXISTS core_cycle_type_check;
ALTER TABLE core_cycle
    ADD CONSTRAINT core_cycle_type_check
    CHECK (type IN ('MCI', 'GOAL', 'OBJECTIVE', 'PROJECT', 'PHASE', 'ROUTINE'));

-- 2. Free-form self-nesting (GTD horizon ladder); parent type is not constrained.
ALTER TABLE core_cycle
    ADD COLUMN IF NOT EXISTS parent_cycle_id UUID REFERENCES core_cycle (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_core_cycle_parent ON core_cycle (parent_cycle_id);

-- 3+4. Backfill and FK repoint — only while core_project (and thus project_id) still exists.
DO $$
BEGIN
    IF to_regclass('public.core_project') IS NOT NULL THEN
        -- Promote every project to a cycle of type PROJECT (id preserved).
        INSERT INTO core_cycle (id, user_id, name, type, status)
        SELECT id, user_id, name, 'PROJECT',
               CASE WHEN status = 'COMPLETED' THEN 'COMPLETED' ELSE 'ACTIVE' END
        FROM core_project
        ON CONFLICT (id) DO NOTHING;

        -- The project (most concrete container) becomes the row's cycle when set.
        UPDATE core_executable SET cycle_id = project_id WHERE project_id IS NOT NULL;
        UPDATE fin_goal        SET cycle_id = project_id WHERE project_id IS NOT NULL;
    END IF;
END $$;

-- 5. Drop the project_id columns and their indexes.
DROP INDEX IF EXISTS idx_core_executable_project;
ALTER TABLE core_executable DROP COLUMN IF EXISTS project_id;
DROP INDEX IF EXISTS idx_fin_goal_project;
ALTER TABLE fin_goal DROP COLUMN IF EXISTS project_id;

-- 6. Drop the CORE_PROJECT entity.
DROP TABLE IF EXISTS core_project;

COMMIT;
