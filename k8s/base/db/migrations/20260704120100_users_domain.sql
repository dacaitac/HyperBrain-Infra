-- DDL v1 — Users domain (ERD v2.0.0)
-- sys_user is the multi-tenant root; every domain table references it via user_id.

CREATE TABLE sys_user (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email          TEXT NOT NULL UNIQUE,
    password_hash  TEXT NOT NULL,
    role           TEXT NOT NULL DEFAULT 'USER'
                       CHECK (role IN ('ADMIN', 'USER')),
    status         TEXT NOT NULL DEFAULT 'ACTIVE'
                       CHECK (status IN ('ACTIVE', 'INACTIVE')),
    timezone       TEXT NOT NULL DEFAULT 'America/Bogota',
    -- Prioritizer weights, throttling threshold, FSRS target retention
    settings       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sys_user IS 'Tenant root. All domain tables reference sys_user.id via user_id.';

CREATE TABLE sync_credential (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    provider       TEXT NOT NULL
                       CHECK (provider IN ('NOTION', 'APPLE', 'N8N')),
    access_token   TEXT,
    refresh_token  TEXT,
    expires_at     TIMESTAMPTZ
);

CREATE INDEX idx_sync_credential_user ON sync_credential (user_id);
