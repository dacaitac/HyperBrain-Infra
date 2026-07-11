-- Agenda block reason (#66 / HU-01b): the one-line rationale the Planner attaches
-- to each PLANNED time block, carried into the body of the iOS calendar event during
-- the agenda write-back (AgendaBlockPropagator). NULL means "no reason recorded".
--
-- Additive, safe over the existing production schema: core_time_block HAS DATA in
-- prod, so the column is nullable and has NO default. Adding a nullable column with
-- no default is a metadata-only change in PostgreSQL (no table rewrite, no lock on
-- existing rows), and every existing row simply reads NULL.
--
-- Applied by hand via psql after human review (never `supabase db push`); see
-- reference: migrations run manually on daniel-ubuntu.
--
-- Idempotent / re-runnable: ADD COLUMN IF NOT EXISTS makes a second application a
-- no-op instead of an error. Transactional.
--
-- Mirror: HyperBrain-core/src/main/resources/db/migration/V1__init.sql (core_time_block)
-- is updated in the same unit of work by core-engineer.

BEGIN;

ALTER TABLE core_time_block
    ADD COLUMN IF NOT EXISTS reason TEXT;

COMMIT;
