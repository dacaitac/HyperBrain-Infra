-- Seeds — applied by `supabase db reset` after migrations.
-- Idempotent (fixed UUIDs + ON CONFLICT) so re-runs are safe.
-- NOTE: password_hash below is a throwaway placeholder bcrypt hash for the local
-- MVP user, NOT a real secret. Rotate via GoTrue before any non-local use.

-- 1) System user (tenant root)
INSERT INTO sys_user (id, email, password_hash, role, status, timezone, settings)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'daniel@hyperbrain.local',
    '$2a$10$C6UzMDM.H6dfI/f/IKcEeO3Jn0gH0000000000000000000000000000',
    'ADMIN',
    'ACTIVE',
    'America/Bogota',
    '{}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- 2) Base financial categories
INSERT INTO fin_category (id, user_id, parent_id, name, flow_type) VALUES
    ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', NULL, 'Salario',       'INCOME'),
    ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', NULL, 'Freelance',     'INCOME'),
    ('10000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', NULL, 'Vivienda',      'EXPENSE'),
    ('10000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', NULL, 'Alimentación',  'EXPENSE'),
    ('10000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', NULL, 'Transporte',    'EXPENSE'),
    ('10000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-000000000001', NULL, 'Servicios',     'EXPENSE'),
    ('10000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-000000000001', NULL, 'Salud',         'EXPENSE'),
    ('10000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000001', NULL, 'Ocio',          'EXPENSE'),
    ('10000000-0000-0000-0000-000000000016', '00000000-0000-0000-0000-000000000001', NULL, 'Ahorro',        'EXPENSE')
ON CONFLICT (id) DO NOTHING;

-- 3) Test learning topic
INSERT INTO lrn_topic (id, user_id, name, description, status, current_score)
VALUES (
    '20000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000001',
    'Spring Boot DDD',
    'Test topic seeded for S0-02 — FSRS scheduling smoke test.',
    'ACTIVE',
    50
)
ON CONFLICT (id) DO NOTHING;
