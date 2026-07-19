-- DDL v1 — Learning domain (ERD v2.0.0)
-- FSRS memory state on topics (ADR-004); assessments feed the FSRS rating.

CREATE TABLE lrn_topic (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    name              TEXT NOT NULL,
    description       TEXT,
    status            TEXT NOT NULL DEFAULT 'ACTIVE'
                          CHECK (status IN ('ACTIVE', 'MASTERED', 'ARCHIVED')),
    current_score     INTEGER CHECK (current_score IS NULL OR current_score BETWEEN 0 AND 100),
    -- FSRS: stability (S, days) and difficulty (D) — ADR-004
    stability         DOUBLE PRECISION,
    difficulty        DOUBLE PRECISION,
    last_review_at    TIMESTAMPTZ,
    next_review_date  TIMESTAMPTZ
);

CREATE INDEX idx_lrn_topic_user ON lrn_topic (user_id);
CREATE INDEX idx_lrn_topic_next_review ON lrn_topic (next_review_date);

-- Owner derivable via topic_id (no user_id column in MVP)
CREATE TABLE lrn_assessment (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic_id            UUID NOT NULL REFERENCES lrn_topic (id) ON DELETE CASCADE,
    executable_id       UUID REFERENCES core_executable (id) ON DELETE SET NULL,
    score_internals     INTEGER CHECK (score_internals IS NULL OR score_internals BETWEEN 0 AND 100),
    score_architecture  INTEGER CHECK (score_architecture IS NULL OR score_architecture BETWEEN 0 AND 100),
    score_production    INTEGER CHECK (score_production IS NULL OR score_production BETWEEN 0 AND 100),
    score_seniority     INTEGER CHECK (score_seniority IS NULL OR score_seniority BETWEEN 0 AND 100),
    -- maps to FSRS rating: <20 Again, 20-69 Hard, 70-84 Good, >=85 Easy
    score_general       INTEGER CHECK (score_general IS NULL OR score_general BETWEEN 0 AND 100),
    identified_gaps     TEXT,
    recommended_prompt  TEXT CHECK (recommended_prompt IS NULL OR
                                    recommended_prompt IN ('A', 'B', 'C', 'D', 'E')),
    assessed_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_lrn_assessment_topic ON lrn_assessment (topic_id);
CREATE INDEX idx_lrn_assessment_executable ON lrn_assessment (executable_id);
