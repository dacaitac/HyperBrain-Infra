# HyperBrain-Infra — Agent Context

This repo uses Claude Code as the primary AI agent. All rules, patterns, and conventions are in `CLAUDE.md` (symlinked from HyperBrain-docs via ADR-007).

See `CLAUDE.md` in this directory for the full agent brief.

**Key pointers for other agent tools:**
- Stack: Docker Compose, Supabase CLI migrations, Terraform (SQS/IAM), SOPS+age secrets
- Validation: `docker compose config --quiet`
- Deploy: self-hosted runner on `daniel-ubuntu`, gate `environment: production`
- Approval policy: [docs/06-agents-and-skills/approval-policy.md](../HyperBrain-docs/docs/06-agents-and-skills/approval-policy.md)
