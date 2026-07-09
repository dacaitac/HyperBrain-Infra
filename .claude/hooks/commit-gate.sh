#!/usr/bin/env bash
# PreToolUse(Bash) commit gate for HyperBrain-Infra (ADR-017 gate #2).
# Blocks `git commit` unless `docker compose config --quiet` validates the stack.
set -euo pipefail

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)"

# Only guard git commits; let everything else through.
echo "$CMD" | grep -qw git && echo "$CMD" | grep -qw commit || exit 0

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

if ! ERR="$(docker compose config --quiet 2>&1)"; then
  echo "COMMIT BLOCKED (ADR-017): 'docker compose config --quiet' failed. Fix the Compose file before committing:" >&2
  echo "$ERR" >&2
  exit 2
fi

exit 0
