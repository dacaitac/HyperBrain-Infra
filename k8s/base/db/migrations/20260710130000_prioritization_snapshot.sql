-- Prioritization snapshot timestamp (#66a): records when the Prioritizer last
-- (re)computed the scores of an executable. NULL means "never computed", so the
-- Prioritizer treats the row as pending on first sight — no backfill required.
--
-- Additive, safe over the existing production schema: core_executable HAS DATA in
-- prod, so the column is nullable and has NO default. Adding a nullable column with
-- no default is a metadata-only change in PostgreSQL (no table rewrite, no lock on
-- existing rows), and every existing row simply reads NULL.
--
-- Scope note: priority_score / urgency_score / effort_score already exist and are
-- untouched. urgency_score keeps its current definition (no CHECK) on purpose, so
-- it can carry the raw 0-6 scale without rejecting existing data. The cycle-tick
-- trigger and any queue changes are #66b (decided with its own ADR); this migration
-- touches schema only.
--
-- Applied by hand via psql after human review (never `supabase db push`); see
-- reference: migrations run manually on daniel-ubuntu.
--
-- Idempotent / re-runnable: ADD COLUMN IF NOT EXISTS makes a second application a
-- no-op instead of an error. Transactional.
--
-- Mirror: HyperBrain-core/src/main/resources/db/migration/V1__init.sql (core_executable)
-- is updated in the same unit of work by core-engineer.

BEGIN;

ALTER TABLE core_executable
    ADD COLUMN IF NOT EXISTS priority_computed_at TIMESTAMPTZ;

COMMIT;
