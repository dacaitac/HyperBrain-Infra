-- ADR-013 (#55): time blocks become the Planner's projection unit; focus & progress accounting.
-- core_time_block gains a lifecycle (PLANNED -> ACTIVE -> SETTLED/EXPIRED): blocks are settled,
-- never stretched, so overrun can no longer overlap the agenda.
-- core_executable gains SYSTEM-owned accounting columns (outside the ADR-012 authority matrix;
-- no external source ever writes them):
--   progress              -> materialized user-subtask progress (NULL = no progress unit)
--   system_generated      -> focus-switch snapshot subtasks (DR-06), excluded from progress
--   pending_reestimation  -> effort emptied after a focus switch, awaiting human confirmation
--   imputed_time_block_id -> block the completed subtask was imputed to on settlement (DR-08)
-- core_time_block is empty in production, so the NOT NULL DEFAULT additions are trivial.

ALTER TABLE core_time_block
    ADD COLUMN status          TEXT NOT NULL DEFAULT 'PLANNED'
        CHECK (status IN ('PLANNED', 'ACTIVE', 'SETTLED', 'EXPIRED')),
    ADD COLUMN origin          TEXT NOT NULL DEFAULT 'PLANNER'
        CHECK (origin IN ('PLANNER', 'FOCUS', 'USER')),
    ADD COLUMN planned_minutes INTEGER,
    ADD COLUMN settled_at      TIMESTAMPTZ,
    ADD COLUMN created_at      TIMESTAMPTZ NOT NULL DEFAULT now();

-- Expiry cron (TimeBlockExpiryScheduler) scans only open blocks.
CREATE INDEX idx_core_time_block_open
    ON core_time_block (status, date_end)
    WHERE status IN ('PLANNED', 'ACTIVE');

ALTER TABLE core_executable
    ADD COLUMN progress             DOUBLE PRECISION
        CHECK (progress IS NULL OR progress BETWEEN 0 AND 1),
    ADD COLUMN system_generated     BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN pending_reestimation BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN imputed_time_block_id UUID REFERENCES core_time_block (id) ON DELETE SET NULL;

CREATE INDEX idx_core_executable_imputed_block
    ON core_executable (imputed_time_block_id);
