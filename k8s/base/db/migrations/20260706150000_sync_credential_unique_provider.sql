-- HU-10 (CA-12): one credential row per (user, provider) so the Notion token upsert
-- (scripts/provision-notion-credential.sh) is idempotent via ON CONFLICT.
-- Additive change; the table is empty at this point in every environment.
ALTER TABLE sync_credential
    ADD CONSTRAINT uq_sync_credential_user_provider UNIQUE (user_id, provider);
