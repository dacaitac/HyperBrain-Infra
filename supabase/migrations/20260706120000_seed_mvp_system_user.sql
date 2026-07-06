-- Seed: default system user for single-user MVP
-- UUID 00000000-0000-0000-0000-000000000001 is the hardcoded default injected via
-- app.sync.default-user-id in application.yml. Must exist before any sync handler
-- writes to core_executable (FK: core_executable.user_id → sys_user.id).
-- Idempotent: ON CONFLICT DO NOTHING is safe on re-run or if inserted manually.

INSERT INTO sys_user (id, email, password_hash, role, status, timezone, settings)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'daniel@hyperbrain.local',
    'x',
    'ADMIN',
    'ACTIVE',
    'America/Bogota',
    '{}'
)
ON CONFLICT (id) DO NOTHING;
