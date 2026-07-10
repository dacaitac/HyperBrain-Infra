-- Domain decision (committee-approved): the core_execution_profile.impact scale
-- narrows from 1-8 to 1-5, aligning it with energy_drain and mental_load (already 1-5).
--
-- Forward migration over the existing production schema (applied by hand via psql;
-- see reference: migrations run manually on daniel-ubuntu). Safe tightening: the only
-- real producer (Notion sync, 5 levels) has never written impact > 5, so no existing
-- row violates BETWEEN 1 AND 5 and no backfill is needed.
--
-- The original constraint was declared inline and unnamed in
-- 20260704120200_core_domain.sql, so PostgreSQL auto-named it
-- core_execution_profile_impact_check (<table>_<column>_check). We drop it
-- defensively (IF EXISTS covers both that auto-name and a re-run) and recreate the
-- range check with an explicit name for future maintainability.
--
-- Idempotent / re-runnable: DROP ... IF EXISTS + a named ADD guarded against the
-- explicit name make a second application a no-op instead of an error. Transactional.
--
-- Mirror: HyperBrain-core/src/main/resources/db/migration/V1__init.sql (Flyway
-- consolidated schema) is updated in the same unit of work by core-engineer so the
-- inline CHECK reads BETWEEN 1 AND 5.

BEGIN;

-- Drop the previous 1-8 range check (auto-named by Postgres from the inline
-- declaration; IF EXISTS also makes re-runs safe).
ALTER TABLE core_execution_profile
    DROP CONSTRAINT IF EXISTS core_execution_profile_impact_check;

-- Guard against a re-run that already installed the explicit constraint name.
ALTER TABLE core_execution_profile
    DROP CONSTRAINT IF EXISTS core_execution_profile_impact_range;

-- Recreate with the narrowed 1-5 scale under an explicit, stable name.
ALTER TABLE core_execution_profile
    ADD CONSTRAINT core_execution_profile_impact_range
    CHECK (impact IS NULL OR impact BETWEEN 1 AND 5);

COMMIT;
