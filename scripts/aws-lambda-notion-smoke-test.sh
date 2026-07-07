#!/usr/bin/env bash
# Prod E2E smoke test for the Notion webhook Lambda (issues #41/#42).
# Fires a synthetic signed event at the Function URL and checks HTTP handling.
# Follow-up (manual): grep the emitted message_id in the Core logs on
# daniel-ubuntu and confirm sync-events-dlq.fifo stays empty.
# Requires: aws CLI with credentials that can read the SSM secret and the
# Function URL (terraform output -raw function_url, or NOTION_WEBHOOK_FUNCTION_URL).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PARAM="${WEBHOOK_SECRET_PARAM:-/hyperbrain/notion/webhook-secret}"
URL="${NOTION_WEBHOOK_FUNCTION_URL:-${1:-}}"
PASS=0; FAIL=0

check() { echo -n "  → $1... "; }
ok()    { echo "✓"; PASS=$((PASS+1)); }
fail()  { echo "✗  $1"; FAIL=$((FAIL+1)); }

if [ -z "${URL}" ]; then
  echo "Usage: $0 <function-url>  (or set NOTION_WEBHOOK_FUNCTION_URL)"; exit 2
fi

echo "=== HyperBrain Notion webhook Lambda smoke test (AWS prod) ==="
echo "Function URL: ${URL}"

SECRET=$(aws ssm get-parameter --region "${REGION}" --name "${PARAM}" \
  --with-decryption --query Parameter.Value --output text)

MESSAGE_ID="prod-smoke-$(date +%s)"
BODY='{"id":"'"${MESSAGE_ID}"'","type":"page.content_updated","entity":{"id":"prod-smoke-entity","type":"page"},"data":{"source":"aws-lambda-smoke-test"}}'
SIG="sha256=$(printf '%s' "${BODY}" | openssl dgst -sha256 -hmac "${SECRET}" -hex | awk '{print $NF}')"

check "Signed synthetic event → HTTP 200"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${URL}" \
  -H "content-type: application/json" -H "x-notion-signature: ${SIG}" \
  --data-raw "${BODY}")
[ "${STATUS}" = "200" ] && ok || fail "HTTP ${STATUS}"

check "Invalid signature → HTTP 401"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${URL}" \
  -H "content-type: application/json" -H "x-notion-signature: sha256=deadbeef" \
  --data-raw "${BODY}")
[ "${STATUS}" = "401" ] && ok || fail "HTTP ${STATUS}"

echo ""
echo "message_id del evento sintético: ${MESSAGE_ID}"
echo "Verificar en el Core (daniel-ubuntu):"
echo "  docker logs hyperbrain-core 2>&1 | grep '${MESSAGE_ID}'"
echo "Verificar DLQ vacía:"
echo "  aws sqs get-queue-attributes --queue-url https://sqs.${REGION}.amazonaws.com/<account>/sync-events-dlq.fifo --attribute-names ApproximateNumberOfMessages"
echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron"
[ ${FAIL} -eq 0 ] && exit 0 || exit 1
