-- DDL v1 — Finance domain (ERD v2.0.0)
-- MVP operates in a single currency; origin/destination must match (validated in domain).

CREATE TABLE fin_account (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id   UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    name      TEXT NOT NULL,
    type      TEXT NOT NULL CHECK (type IN ('ASSET', 'LIABILITY')),
    balance   NUMERIC(19, 4) NOT NULL DEFAULT 0,
    currency  TEXT NOT NULL DEFAULT 'COP'
);

CREATE INDEX idx_fin_account_user ON fin_account (user_id);

CREATE TABLE fin_category (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    parent_id  UUID REFERENCES fin_category (id) ON DELETE SET NULL,
    name       TEXT NOT NULL,
    flow_type  TEXT NOT NULL CHECK (flow_type IN ('INCOME', 'EXPENSE'))
);

CREATE INDEX idx_fin_category_user ON fin_category (user_id);
CREATE INDEX idx_fin_category_parent ON fin_category (parent_id);

-- Template for the BudgetCycleStartEvent cron (Finance Engine)
CREATE TABLE fin_budget_template (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    category_id   UUID NOT NULL REFERENCES fin_category (id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    period        TEXT NOT NULL
                      CHECK (period IN ('WEEKLY', 'BIWEEKLY', 'MONTHLY', 'CUSTOM')),
    limit_amount  NUMERIC(19, 4) NOT NULL,
    carry_policy  TEXT NOT NULL DEFAULT 'RESET'
                      CHECK (carry_policy IN ('ROLLOVER', 'RESET')),
    active        BOOLEAN NOT NULL DEFAULT true
);

CREATE INDEX idx_fin_budget_template_user ON fin_budget_template (user_id);
CREATE INDEX idx_fin_budget_template_category ON fin_budget_template (category_id);

CREATE TABLE fin_budget (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    category_id   UUID NOT NULL REFERENCES fin_category (id) ON DELETE CASCADE,
    template_id   UUID REFERENCES fin_budget_template (id) ON DELETE SET NULL,
    name          TEXT NOT NULL,
    start_date    DATE NOT NULL,
    end_date      DATE NOT NULL,
    limit_amount  NUMERIC(19, 4) NOT NULL,
    carry_policy  TEXT NOT NULL DEFAULT 'RESET'
                      CHECK (carry_policy IN ('ROLLOVER', 'RESET')),
    -- flagged by BudgetExceededEvent (budget-alert workflow)
    exceeded      BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX idx_fin_budget_user ON fin_budget (user_id);
CREATE INDEX idx_fin_budget_category ON fin_budget (category_id);
CREATE INDEX idx_fin_budget_template ON fin_budget (template_id);

CREATE TABLE fin_goal (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    cycle_id           UUID REFERENCES core_cycle (id) ON DELETE SET NULL,
    project_id         UUID REFERENCES core_project (id) ON DELETE SET NULL,
    name               TEXT NOT NULL,
    goal_type          TEXT NOT NULL DEFAULT 'STANDARD'
                           CHECK (goal_type IN ('STANDARD', 'GENERAL_POOL')),
    -- GENERAL_POOL: dynamic sum of linked executables' estimated_cost (RF-14)
    target_amount      NUMERIC(19, 4),
    accumulated_amount NUMERIC(19, 4) NOT NULL DEFAULT 0,
    status             TEXT NOT NULL DEFAULT 'SAVING'
                           CHECK (status IN ('SAVING', 'FUNDED', 'COMPLETED')),
    target_date        DATE
);

CREATE INDEX idx_fin_goal_user ON fin_goal (user_id);
CREATE INDEX idx_fin_goal_cycle ON fin_goal (cycle_id);
CREATE INDEX idx_fin_goal_project ON fin_goal (project_id);

-- Owner derivable via origin/destination account (no user_id column in MVP)
CREATE TABLE fin_transaction (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    executable_id           UUID REFERENCES core_executable (id) ON DELETE SET NULL,
    origin_account_id       UUID REFERENCES fin_account (id) ON DELETE SET NULL,
    destination_account_id  UUID REFERENCES fin_account (id) ON DELETE SET NULL,
    category_id             UUID REFERENCES fin_category (id) ON DELETE SET NULL,
    cycle_id                UUID REFERENCES core_cycle (id) ON DELETE SET NULL,
    -- goal_id materializes "FIN_GOAL contributes to FIN_TRANSACTION" (ERD relationship)
    goal_id                 UUID REFERENCES fin_goal (id) ON DELETE SET NULL,
    amount                  NUMERIC(19, 4) NOT NULL,
    currency                TEXT NOT NULL DEFAULT 'COP',
    description             TEXT,
    type                    TEXT NOT NULL
                                CHECK (type IN ('INCOME', 'EXPENSE', 'TRANSFER')),
    status                  TEXT NOT NULL DEFAULT 'COMPLETED'
                                CHECK (status IN ('PLANNED', 'PENDING', 'COMPLETED')),
    occurred_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fin_transaction_origin ON fin_transaction (origin_account_id);
CREATE INDEX idx_fin_transaction_destination ON fin_transaction (destination_account_id);
CREATE INDEX idx_fin_transaction_category ON fin_transaction (category_id);
CREATE INDEX idx_fin_transaction_cycle ON fin_transaction (cycle_id);
CREATE INDEX idx_fin_transaction_goal ON fin_transaction (goal_id);
CREATE INDEX idx_fin_transaction_executable ON fin_transaction (executable_id);
CREATE INDEX idx_fin_transaction_occurred ON fin_transaction (occurred_at);

-- Monthly net-worth snapshot (cron); history is not reconstructable from balances
CREATE TABLE fin_networth_snapshot (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            UUID NOT NULL REFERENCES sys_user (id) ON DELETE CASCADE,
    snapshot_date      DATE NOT NULL,
    total_assets       NUMERIC(19, 4) NOT NULL,
    total_liabilities  NUMERIC(19, 4) NOT NULL,
    net_worth          NUMERIC(19, 4) NOT NULL,
    UNIQUE (user_id, snapshot_date)
);

CREATE INDEX idx_fin_networth_snapshot_user ON fin_networth_snapshot (user_id);
