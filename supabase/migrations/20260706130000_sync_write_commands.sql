-- HU-09c (#37): outbound write-back Core → Apple (ADR-010).
-- Correlation log for WriteCommands published to apple-commands.fifo. On operation=CREATED the
-- EventKit entity_id does not exist yet; the WriteCommandResult consumed from
-- apple-commands-results.fifo is correlated by command_id against this table to close the
-- sync_mapping. The stored payload replays the checksum once the entity_id is known (RF-17).
CREATE TABLE sync_write_commands (
    command_id    UUID PRIMARY KEY,
    user_id       UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    local_id      UUID NOT NULL,
    command_type  TEXT NOT NULL CHECK (command_type IN ('REMINDER', 'CALENDAR_EVENT')),
    operation     TEXT NOT NULL CHECK (operation IN ('CREATED', 'UPDATED', 'DELETED')),
    entity_id     TEXT,
    payload       JSONB,
    status        TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPLIED', 'FAILED')),
    error         TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at   TIMESTAMPTZ
);

CREATE INDEX idx_sync_write_commands_pending
    ON sync_write_commands (created_at)
    WHERE status = 'PENDING';

CREATE INDEX idx_sync_write_commands_local ON sync_write_commands (local_id);
