-- DDL v1 — Sync mappings and event-driven pipeline infrastructure (ERD v2.0.0)

CREATE TABLE sync_mappings (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    -- polymorphic local aggregate (executable, transaction, ...): no hard FK
    local_id            UUID NOT NULL,
    external_system     TEXT NOT NULL CHECK (external_system IN ('NOTION', 'APPLE')),
    external_id         TEXT NOT NULL,
    last_known_checksum TEXT,
    sync_status         TEXT,
    last_synced_at      TIMESTAMPTZ,
    UNIQUE (external_system, external_id)
);

CREATE INDEX idx_sync_mappings_user ON sync_mappings (user_id);
CREATE INDEX idx_sync_mappings_local ON sync_mappings (local_id);

-- Transactional Outbox: written in the same tx as the aggregate change,
-- drained by OutboxWorker (FOR UPDATE SKIP LOCKED) then marked processed.
CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type  TEXT NOT NULL,
    aggregate_id    TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    payload         JSONB NOT NULL,
    processed       BOOLEAN NOT NULL DEFAULT false,
    processed_at    TIMESTAMPTZ,
    -- loop protection: don't re-emit events originated by an external sync (RF-17)
    source_system   TEXT,
    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Partial index over the drain hot path (unprocessed events, oldest first)
CREATE INDEX idx_outbox_events_unprocessed
    ON outbox_events (occurred_at)
    WHERE processed = false;

-- Consumer-side dedup for SQS at-least-once delivery (idempotency)
CREATE TABLE processed_message (
    message_id    TEXT PRIMARY KEY,
    event_type    TEXT,
    processed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
