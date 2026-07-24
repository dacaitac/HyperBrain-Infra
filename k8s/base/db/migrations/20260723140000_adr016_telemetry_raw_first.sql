-- ADR-016 (#59): raw-first telemetry ingestion with deferred normalization.
--
-- context_event becomes the canonical RAW landing zone: the TelemetryConsumer inserts
-- every TelemetryEnvelope here BEFORE any interpretation, so ingestion never fails on
-- format. Typed tel_* tables are projected by the TelemetryNormalizer (Strategy per
-- provider+event_type) ONLY for the metrics an engine consumes (schema-on-read by
-- default; schema-on-write on demand). Engines and read-models read the typed tables,
-- never the raw JSONB.
--
-- This migration does four things, all part of the ADR-016 v1.4.0 decision:
--   1. Extends context_event with the raw-first ingestion columns (dedup_key,
--      schema_version, ingested_at, normalization_status) + supporting indexes.
--   2. Adds a new typed table tel_app_usage for Screen Time / DeviceActivity buckets
--      (NOT tel_activity_stream — that is the RescueTime-desktop schema; iOS
--      DeviceActivity has no window_title and aggregates at the edge by category).
--   3. Adds context_event_id traceability from tel_sleep_record back to the raw row.
--   4. Adds the retention-support index for the context_event purge (core-side
--      @Scheduled sweep, mirroring the outbox retention; the raw zone's growth stops
--      being theoretical once Screen Time flows).
--
-- Applied by the db-migrate Job (ADR-021 D3/F4'): the runner wraps each file in
-- --single-transaction and commits the infra.schema_migrations ledger row atomically
-- with the migration, so this file intentionally carries NO explicit BEGIN/COMMIT.
--
-- Applied by hand via psql after human review (never `supabase db push`); see
-- reference: migrations run manually on daniel-ubuntu. NOT applied to prod by the AI.
--
-- Idempotent / re-runnable: ADD COLUMN IF NOT EXISTS + CREATE ... IF NOT EXISTS make a
-- second application a no-op; the ledger also prevents re-application on an
-- already-migrated cluster.
--
-- Mirror note (S0-07): HyperBrain-core/src/main/resources/db/migration/V1__init.sql is
-- updated in the SAME unit of work by core-engineer — context_event's four new columns,
-- tel_sleep_record.context_event_id and the whole tel_app_usage table are read/written
-- by the TelemetryConsumer/TelemetryNormalizer via JDBC/JPA, so Testcontainers
-- (ddl-auto: validate) MUST know about them. Keep the two in lockstep.
--
-- Additive only (MVP rule): no DROP, no non-additive change.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 — context_event: raw-first ingestion columns.
--   * dedup_key: semantic idempotency key (provider + external id, or a content hash
--     when the provider has none). NULL is allowed for pre-existing non-telemetry rows;
--     uniqueness is enforced by a PARTIAL unique index over the non-null values so
--     legacy rows never collide. The envelope's event_id covers SQS at-least-once
--     retries; dedup_key covers semantic duplicates across redeliveries/reprocessing.
--   * schema_version: version of the provider payload format (tolerant reader in the
--     normalizer). Nullable — legacy rows predate it.
--   * ingested_at: when the Core landed the row (distinct from occurred_at = when the
--     fact happened). Drives the retention sweep.
--   * normalization_status: lifecycle of the raw row. PENDING on insert; the normalizer
--     sets NORMALIZED / ERROR; an envelope with no matching (provider, event_type)
--     strategy is SKIPPED (stays queryable/RAG-indexable, never DLQ'd).
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE context_event
    ADD COLUMN IF NOT EXISTS dedup_key            TEXT,
    ADD COLUMN IF NOT EXISTS schema_version       TEXT,
    ADD COLUMN IF NOT EXISTS ingested_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS normalization_status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (normalization_status IN ('PENDING', 'NORMALIZED', 'SKIPPED', 'ERROR'));

-- Semantic dedup: at most one raw row per external fact. Partial over non-null so the
-- pre-existing rows (dedup_key IS NULL) are exempt.
CREATE UNIQUE INDEX IF NOT EXISTS uq_context_event_dedup_key
    ON context_event (dedup_key)
    WHERE dedup_key IS NOT NULL;

-- Reprocessing scan: a new/fixed normalizer re-runs over PENDING/ERROR rows cheaply.
CREATE INDEX IF NOT EXISTS idx_context_event_norm_pending
    ON context_event (normalization_status)
    WHERE normalization_status IN ('PENDING', 'ERROR');

-- Retention sweep support: the purge deletes NORMALIZED/SKIPPED rows past the cutoff
-- (ERROR rows are kept for diagnosis). Partial index makes the sweep an index-only scan.
CREATE INDEX IF NOT EXISTS idx_context_event_retention
    ON context_event (ingested_at)
    WHERE normalization_status IN ('NORMALIZED', 'SKIPPED');

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 — tel_app_usage: typed Screen Time / DeviceActivity table (ADR-016 v1.3/v1.4).
--   The iOS app aggregates at the edge and sends ONE row per (category, time bucket),
--   never per-window streams — DeviceActivity exposes no window_title. Distinct from
--   tel_activity_stream (RescueTime-desktop schema), which is left untouched.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tel_app_usage (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    bucket_start      TIMESTAMPTZ NOT NULL,
    bucket_end        TIMESTAMPTZ NOT NULL,
    category          TEXT NOT NULL,          -- DeviceActivity ActivityCategory token (open set)
    duration_seconds  INTEGER NOT NULL,
    pickups           INTEGER,                -- nullable: not every provider reports pickups
    context_event_id  UUID REFERENCES context_event (id) ON DELETE SET NULL,
    collected_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Read pattern: "recent usage for a user, newest first" (engine/read-model windows).
CREATE INDEX IF NOT EXISTS idx_tel_app_usage_user_bucket
    ON tel_app_usage (user_id, bucket_start DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3 — tel_sleep_record: traceability back to the raw envelope. Optional (manual-score
--     marker rows written by JdbcSleepScoreStore have no raw origin), FK nulled on the
--     raw row's deletion so retention never cascades into typed sleep data.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE tel_sleep_record
    ADD COLUMN IF NOT EXISTS context_event_id UUID REFERENCES context_event (id) ON DELETE SET NULL;
