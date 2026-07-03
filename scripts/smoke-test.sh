#!/usr/bin/env bash
# Validates the full dev environment end-to-end.
# Exit 0 = environment ready to develop.
# Note: check #4 (sys_user table) fails until S0-02 (DDL v1) is applied.
set -euo pipefail
PASS=0; FAIL=0; WARN=0
check() { echo -n "  → $1... "; }
ok()    { echo "✓"; PASS=$((PASS+1)); }
fail()  { echo "✗  $1"; FAIL=$((FAIL+1)); }
warn()  { echo "⚠  $1 (pendiente)"; WARN=$((WARN+1)); }

echo "=== HyperBrain Dev Environment Smoke Test ==="

# 1. All mandatory services healthy
# docker compose ps --format json outputs NDJSON (one object per line)
check "Servicios Docker healthy"
UNHEALTHY=$(docker compose ps --format json \
  | jq -r 'select(.Service != "sqs-init") | select(.Health != "healthy") | .Service')
[ -z "$UNHEALTHY" ] && ok || fail "No healthy: $UNHEALTHY"

# 2. PostgreSQL responds
check "PostgreSQL conectividad"
docker compose exec -T postgres pg_isready \
  -U "${POSTGRES_USER:-hyperbrain}" -d "${POSTGRES_DB:-hyperbrain}" -q && ok || fail "pg_isready falló"

# 3. pgvector extension active
check "pgvector extension"
docker compose exec -T postgres psql \
  -U "${POSTGRES_USER:-hyperbrain}" -d "${POSTGRES_DB:-hyperbrain}" -tAc \
  "SELECT extname FROM pg_extension WHERE extname = 'vector'" \
  | grep -q vector && ok || fail "pgvector no instalada"

# 4. DDL applied (root table exists) — requires S0-02; warn only until DDL is applied
check "Schema DDL aplicado (sys_user)"
docker compose exec -T postgres psql \
  -U "${POSTGRES_USER:-hyperbrain}" -d "${POSTGRES_DB:-hyperbrain}" -tAc \
  "SELECT to_regclass('public.sys_user')" | grep -q sys_user \
  && ok || warn "sys_user no existe — aplicar DDL v1 (S0-02)"

# 5. SQS queues in LocalStack — uses awslocal inside the localstack container (no region config needed)
check "SQS: 6 colas en LocalStack"
QUEUES=$(docker compose exec -T localstack \
  awslocal sqs list-queues \
  --query 'QueueUrls' --output text 2>/dev/null || echo "")
EXPECTED="sync-events.fifo core-events ia-jobs sync-events-dlq.fifo core-events-dlq ia-jobs-dlq"
ALL_FOUND=true
for q in $EXPECTED; do echo "$QUEUES" | grep -q "$q" || ALL_FOUND=false; done
$ALL_FOUND && ok || fail "Faltan colas SQS"

# 6. GoTrue (Supabase Auth)
check "GoTrue /health"
curl -sf http://localhost:9999/health | jq -e '.name == "GoTrue"' -r > /dev/null \
  && ok || fail "GoTrue no responde"

# 7. PostgREST
check "PostgREST API"
curl -sf http://localhost:3000/ | jq -e '. != null' -r > /dev/null \
  && ok || fail "PostgREST no responde"

# 8. HyperBrain-core (only if running)
if docker compose ps hyperbrain-core 2>/dev/null | grep -q "running\|Up"; then
  check "HyperBrain-core /actuator/health"
  curl -sf http://localhost:8080/actuator/health | jq -e '.status == "UP"' -r > /dev/null \
    && ok || fail "Core no healthy"
fi

echo ""
echo "Resultado: $PASS pasaron, $FAIL fallaron, $WARN advertencias"
[ $FAIL -eq 0 ] && echo "✓ Entorno listo para desarrollar" && exit 0 \
               || echo "✗ Revisar los servicios con fallo" && exit 1
