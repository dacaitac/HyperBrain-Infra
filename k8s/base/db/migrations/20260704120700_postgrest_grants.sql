-- DDL v1 — PostgREST grants (Supabase minimal profile)
-- The Core accesses PostgreSQL directly via JDBC; PostgREST/authenticated is only
-- for HyperBrain-ios-App (ADR-024). Grant CRUD to `authenticated`; `anon` gets nothing yet.

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Apply the same grants to tables created by future migrations
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO authenticated;
