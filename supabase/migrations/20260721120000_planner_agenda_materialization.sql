-- HU-01c H2 (#64): idempotency ledger for the single "materialization owner" of
-- the daily agenda. A single consumer over ia-jobs materializes the agenda; this
-- table makes that materialization idempotent against SQS at-least-once redelivery
-- and redundant replans. The claim is (user_id, agenda_date, input_hash): the same
-- inputs for a given user+day materialize exactly once.
--
-- Baseline approved by Daniel: UNIQUE(user_id, agenda_date, input_hash), here the
-- composite PRIMARY KEY (which is the claim key and the natural dedup constraint).
--
-- HARMLESS UNTIL FLIPPED: this table is unused until Daniel enables the consumer
-- flags (app.sync.async-enabled / agenda-job-consumer.enabled), both default OFF.
-- The flag flip is Daniel's gated decision and is NOT touched here (no k8s/* change).
-- Creating an empty table is safe to apply in the next deploy: metadata-only, no
-- lock on existing data, no read/write path exercises it while the flags are OFF.
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically
-- with the migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Idempotent within a fresh cluster bootstrap; the ledger prevents re-application on
-- an already-migrated cluster.
--
-- Mirror: HyperBrain-core/src/main/resources/db/migration/V1__init.sql
-- (planner_agenda_materialization) is the schema-of-record for Testcontainers and is
-- updated in the same unit of work by core-engineer.

CREATE TABLE planner_agenda_materialization (
    user_id         UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    agenda_date     DATE NOT NULL,
    input_hash      TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'MATERIALIZED'
                        CHECK (status IN ('MATERIALIZED', 'DEGRADED')),
    materialized_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, agenda_date, input_hash)
);

CREATE INDEX idx_planner_agenda_materialization_day
    ON planner_agenda_materialization (user_id, agenda_date);
