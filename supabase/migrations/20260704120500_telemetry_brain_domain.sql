-- DDL v1 — Telemetry, Brain (cognitive) and RAG domain (ERD v2.0.0)

CREATE TABLE tel_sleep_record (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    start_time        TIMESTAMPTZ NOT NULL,
    end_time          TIMESTAMPTZ,
    duration_minutes  INTEGER,
    sleep_score       INTEGER,
    stages            JSONB,
    collected_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_tel_sleep_record_user ON tel_sleep_record (user_id);

CREATE TABLE tel_activity_stream (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    app_name          TEXT,
    window_title      TEXT,
    start_time        TIMESTAMPTZ NOT NULL,
    duration_seconds  INTEGER,
    is_afk            BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX idx_tel_activity_stream_user ON tel_activity_stream (user_id);

CREATE TABLE brain_idea (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    title            TEXT,
    content          TEXT,
    idea_type        TEXT NOT NULL DEFAULT 'CAPTURE'
                         CHECK (idea_type IN ('CAPTURE', 'REFLECTION')),
    status           TEXT NOT NULL DEFAULT 'RAW'
                         CHECK (status IN ('RAW', 'REFINING', 'SOMEDAY',
                                           'REFERENCE', 'ARCHIVED', 'CONVERTED')),
    -- when CONVERTED, points to the executable it became
    converted_to_id  UUID REFERENCES core_executable (id) ON DELETE SET NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_brain_idea_user ON brain_idea (user_id);
CREATE INDEX idx_brain_idea_converted ON brain_idea (converted_to_id);

CREATE TABLE context_event (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    source       TEXT NOT NULL CHECK (source IN ('MANUAL', 'SYSTEM', 'INTEGRATION')),
    provider     TEXT,
    event_type   TEXT,
    content      TEXT,
    payload      JSONB,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_context_event_user ON context_event (user_id);

-- RAG vector store (ADR-003). Polymorphic source via source_type/source_id.
-- embedding dimension: 768 (nomic-embed-text via local Ollama-MLX, ADR-005).
-- If the embedding model changes, adjust vector(N) and rebuild the HNSW index.
CREATE TABLE rag_embedding (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    source_type  TEXT NOT NULL
                     CHECK (source_type IN ('BRAIN_IDEA', 'INTERACTION', 'REFLECTION')),
    source_id    UUID,
    content      TEXT,
    embedding    vector(768),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_rag_embedding_user ON rag_embedding (user_id);
CREATE INDEX idx_rag_embedding_source ON rag_embedding (source_type, source_id);
-- HNSW ANN index with cosine distance (standard for text embeddings)
CREATE INDEX idx_rag_embedding_hnsw
    ON rag_embedding USING hnsw (embedding vector_cosine_ops);
