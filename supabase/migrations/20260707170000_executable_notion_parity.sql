-- ADR-012 D4 (#15): 1:1 parity with the Notion Tasks database.
-- Each column is owned by its epic:
--   is_important      -> Prioritizer (HU-01, Eisenhower axis of the Priority Score)
--   frequency         -> Habits/routines (Atomic Habits)
--   learning_topic_id -> Learning/FSRS (relation resolution activates with that epic)
-- The Notion "Gasto" relation needs no column: it is the existing inverse FK
-- fin_transaction.executable_id (activates with the Finance epic).

ALTER TABLE core_executable
    ADD COLUMN is_important      BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN frequency         DOUBLE PRECISION,
    ADD COLUMN learning_topic_id UUID;

ALTER TABLE core_executable
    ADD CONSTRAINT fk_core_executable_learning_topic
        FOREIGN KEY (learning_topic_id) REFERENCES lrn_topic (id) ON DELETE SET NULL;

CREATE INDEX idx_core_executable_learning ON core_executable (learning_topic_id);
