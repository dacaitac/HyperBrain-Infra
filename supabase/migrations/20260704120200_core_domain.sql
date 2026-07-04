-- DDL v1 — Core domain (ERD v2.0.0)
-- Execution model: cycles (4DX/routines) organize executables; projects group them.

CREATE TABLE core_project (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id  UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    name     TEXT NOT NULL,
    status   TEXT NOT NULL DEFAULT 'ACTIVE'
);

CREATE INDEX idx_core_project_user ON core_project (user_id);

CREATE TABLE core_cycle (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    name           TEXT NOT NULL,
    start_date     DATE,
    end_date       DATE,
    type           TEXT NOT NULL
                       CHECK (type IN ('MCI', 'ROUTINE', 'PHASE')),
    status         TEXT NOT NULL DEFAULT 'ACTIVE'
                       CHECK (status IN ('ACTIVE', 'COMPLETED')),
    -- WOOP wizard (MCI only): internal obstacle + if-then plan (Coaching)
    woop_obstacle  TEXT,
    woop_plan      TEXT
);

CREATE INDEX idx_core_cycle_user ON core_cycle (user_id);

CREATE TABLE core_executable (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    -- Hierarchy (subtasks) and GTD "Waiting For" blocker, both self-referential
    parent_id          UUID REFERENCES core_executable (id) ON DELETE CASCADE,
    blocked_by         UUID REFERENCES core_executable (id) ON DELETE SET NULL,
    cycle_id           UUID REFERENCES core_cycle (id) ON DELETE SET NULL,
    -- project_id materializes "CORE_PROJECT groups CORE_EXECUTABLE" (ERD relationship)
    project_id         UUID REFERENCES core_project (id) ON DELETE SET NULL,
    name               TEXT NOT NULL,
    description        TEXT,
    type               TEXT NOT NULL
                           CHECK (type IN ('TASK', 'HABIT', 'LEAD_MEASURE',
                                           'ACTIVITY', 'AGENDA', 'LEARNING_SESSION')),
    status             TEXT NOT NULL DEFAULT 'TODO'
                           CHECK (status IN ('TODO', 'IN_PROGRESS', 'DONE',
                                             'FAILED', 'PLANNED', 'WAITING')),
    priority_score     DOUBLE PRECISION
                           CHECK (priority_score IS NULL OR priority_score BETWEEN 0 AND 1),
    urgency_score      DOUBLE PRECISION,
    effort_score       DOUBLE PRECISION
                           CHECK (effort_score IS NULL OR effort_score BETWEEN 0 AND 5),
    estimated_cost     NUMERIC(19, 4),
    -- Streaks (Atomic Habits, Law 4) — apply to HABIT type
    current_streak     INTEGER NOT NULL DEFAULT 0,
    best_streak        INTEGER NOT NULL DEFAULT 0,
    last_completed_at  TIMESTAMPTZ,
    start_time         TIMESTAMPTZ,
    end_time           TIMESTAMPTZ,
    source_calendar    TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_core_executable_user ON core_executable (user_id);
CREATE INDEX idx_core_executable_parent ON core_executable (parent_id);
CREATE INDEX idx_core_executable_cycle ON core_executable (cycle_id);
CREATE INDEX idx_core_executable_project ON core_executable (project_id);
CREATE INDEX idx_core_executable_status ON core_executable (status);

-- One-to-one execution profile; owner derivable via executable_id (no user_id in MVP)
CREATE TABLE core_execution_profile (
    executable_id      UUID PRIMARY KEY REFERENCES core_executable (id) ON DELETE CASCADE,
    estimated_minutes  INTEGER,
    energy_drain       INTEGER CHECK (energy_drain IS NULL OR energy_drain BETWEEN 1 AND 5),
    mental_load        INTEGER CHECK (mental_load IS NULL OR mental_load BETWEEN 1 AND 5),
    impact             INTEGER CHECK (impact IS NULL OR impact BETWEEN 1 AND 8),
    -- GTD location context
    context_location   TEXT CHECK (context_location IS NULL OR
                                   context_location IN ('CASA', 'OFICINA', 'RECADOS', 'ANY'))
);

-- Time tracking; owner derivable via executable_id (no user_id in MVP)
CREATE TABLE core_time_block (
    id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    executable_id             UUID NOT NULL REFERENCES core_executable (id) ON DELETE CASCADE,
    date_start                TIMESTAMPTZ NOT NULL,
    date_end                  TIMESTAMPTZ,
    actual_duration_minutes   INTEGER
);

CREATE INDEX idx_core_time_block_executable ON core_time_block (executable_id);
