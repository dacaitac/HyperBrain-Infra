-- ADR-036 (#53): CORE_CYCLE gains the AREA type — a perpetual life-area classification — and a
-- MANY-TO-MANY membership: a cycle "serves" N areas through the core_cycle_area bridge.
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically with the
-- migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Reviewed by Daniel BEFORE it reaches prod (never `supabase db push` from the AI, never applied
-- to prod by the AI). Tested locally against a throwaway container built from these migrations.
--
-- Idempotent / re-runnable: DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT (name reused) +
-- CREATE TABLE/INDEX IF NOT EXISTS make a second application a no-op; the ledger also prevents
-- re-application on an already-migrated cluster.
--
-- Additive only (MVP rule): no DROP TABLE/COLUMN, no table rewrite. No backfill: no row is AREA yet.
--
-- Mirror note (S0-07): HyperBrain-core/src/main/resources/db/migration/V1__init.sql is updated in
-- the SAME unit of work (by core-engineer) — the core reads/writes core_cycle.type='AREA' and
-- core_cycle_area via JDBC/JPA, so Testcontainers (ddl-auto: validate) MUST know about them.
-- Keep the two in lockstep.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 — Extend the core_cycle.type CHECK to admit 'AREA'.
-- type is TEXT + CHECK (not a PG enum): no ALTER TYPE hazard. Dropping and re-adding the SAME
-- constraint name inside the single transaction is atomic and lock-cheap (a validate scan of an
-- empty-to-tiny table). Existing values preserved, 'AREA' appended.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_cycle DROP CONSTRAINT IF EXISTS core_cycle_type_check;
ALTER TABLE public.core_cycle
    ADD CONSTRAINT core_cycle_type_check
    CHECK (type IN ('MCI', 'GOAL', 'OBJECTIVE', 'PROJECT', 'PHASE', 'ROUTINE', 'AREA'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 — Perpetuity invariant: an AREA never carries a deadline, so it can never inject an end_date
-- into the urgency chain (ADR-026: urgency = MIN(core_cycle.end_date) over the ACTIVE chain).
-- Non-AREA rows are unconstrained. Every existing row satisfies it (none is AREA), so ADD is valid.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.core_cycle DROP CONSTRAINT IF EXISTS core_cycle_area_perpetual;
ALTER TABLE public.core_cycle
    ADD CONSTRAINT core_cycle_area_perpetual
    CHECK (type <> 'AREA' OR end_date IS NULL);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3 — core_cycle_area: the M:N bridge. A cycle (any type) "serves" N areas.
--   cycle_id -- the serving cycle (MCI/GOAL/PROJECT/...).
--   area_id  -- the area served. It MUST reference a core_cycle whose type='AREA'. A plain FK
--               cannot express that predicate, so it is enforced by the DOMAIN (a core DomainRule),
--               NOT by a trigger: the MVP has a single writer (the core), the rule is cheap to
--               assert in-process, and a cross-row trigger would add operational weight and a
--               second source of truth. The gap is intentional and documented here.
-- Ownership is DERIVED through core_cycle.user_id (both endpoints are cycles): the bridge carries
-- no user_id, mirroring core_time_block_member (ADR-027). No RLS in this schema; tenancy is the
-- user_id column on the owning tables.
-- PK (cycle_id, area_id): uniqueness of a membership + covers the "areas served by this cycle" scan.
-- CHECK (cycle_id <> area_id): a cycle cannot serve itself.
-- ON DELETE CASCADE on both FKs: deleting either endpoint clears the membership.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.core_cycle_area (
    cycle_id UUID NOT NULL REFERENCES public.core_cycle (id) ON DELETE CASCADE,
    area_id  UUID NOT NULL REFERENCES public.core_cycle (id) ON DELETE CASCADE,
    PRIMARY KEY (cycle_id, area_id),
    CONSTRAINT core_cycle_area_no_self CHECK (cycle_id <> area_id)
);

-- Lookup "which cycles serve this area": area_id is the non-prefix side of the PK, so it needs its
-- own index. (cycle_id is the PK prefix → "which areas does this cycle serve" is already covered.)
CREATE INDEX IF NOT EXISTS idx_core_cycle_area_area ON public.core_cycle_area (area_id);
