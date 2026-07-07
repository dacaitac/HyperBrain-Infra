#!/usr/bin/env bash
# Prod E2E smoke test for the Notion webhook Lambda (issues #41/#42).
# Fires synthetic events at the Function URL covering both auth channels
# (HMAC subscription + X-HyperBrain-Token automation) and the drop-but-200 path.
# Follow-up (manual): grep the emitted message_ids in the Core logs on
# daniel-ubuntu and confirm sync-events-dlq.fifo stays empty.
# Requires: aws CLI with credentials that can read both SSM secrets and the
# Function URL (terraform output -raw function_url, or NOTION_WEBHOOK_FUNCTION_URL).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SECRET_PARAM="${WEBHOOK_SECRET_PARAM:-/hyperbrain/notion/webhook-secret}"
TOKEN_PARAM="${AUTOMATION_TOKEN_PARAM:-/hyperbrain/notion/automation-token}"
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

SECRET=$(aws ssm get-parameter --region "${REGION}" --name "${SECRET_PARAM}" \
  --with-decryption --query Parameter.Value --output text)
TOKEN=$(aws ssm get-parameter --region "${REGION}" --name "${TOKEN_PARAM}" \
  --with-decryption --query Parameter.Value --output text)

post() { # $1=body $2=extra header (may be empty) → prints http_code
  if [ -n "$2" ]; then
    curl -s -o /dev/null -w '%{http_code}' -X POST "${URL}" \
      -H "content-type: application/json" -H "$2" --data-raw "$1"
  else
    curl -s -o /dev/null -w '%{http_code}' -X POST "${URL}" \
      -H "content-type: application/json" --data-raw "$1"
  fi
}

SUB_ID="prod-smoke-sub-$(date +%s)"
AUTO_ID="prod-smoke-auto-$(date +%s)"
SUB_BODY='{"id":"'"${SUB_ID}"'","type":"page.content_updated","entity":{"id":"prod-smoke-entity","type":"page"},"data":{"source":"aws-lambda-smoke-test"}}'
AUTO_BODY='{"id":"'"${AUTO_ID}"'","type":"automation","entity":{"id":"prod-smoke-entity","type":"page"},"data":{"source":"aws-lambda-smoke-test"}}'
SIG="sha256=$(printf '%s' "${SUB_BODY}" | openssl dgst -sha256 -hmac "${SECRET}" -hex | awk '{print $NF}')"

check "Signed subscription event → HTTP 200"
STATUS=$(post "${SUB_BODY}" "x-notion-signature: ${SIG}")
[ "${STATUS}" = "200" ] && ok || fail "HTTP ${STATUS}"

check "Automation event with valid X-HyperBrain-Token → HTTP 200"
STATUS=$(post "${AUTO_BODY}" "x-hyperbrain-token: ${TOKEN}")
[ "${STATUS}" = "200" ] && ok || fail "HTTP ${STATUS}"

check "Tampered signature → HTTP 200 (dropped, not forwarded)"
STATUS=$(post "${SUB_BODY}" "x-notion-signature: sha256=deadbeef")
[ "${STATUS}" = "200" ] && ok || fail "HTTP ${STATUS}"

check "Wrong automation token → HTTP 200 (dropped)"
STATUS=$(post "${AUTO_BODY}" "x-hyperbrain-token: wrong-token")
[ "${STATUS}" = "200" ] && ok || fail "HTTP ${STATUS}"

echo ""
echo "message_ids forwarded (subscription + automation): ${SUB_ID} , ${AUTO_ID}"
echo "Verificar en el Core (daniel-ubuntu):"
echo "  docker logs hyperbrain-core 2>&1 | grep -E '${SUB_ID}|${AUTO_ID}'"
echo "Verificar DLQ vacía:"
echo "  aws sqs get-queue-attributes --queue-url https://sqs.${REGION}.amazonaws.com/<account>/sync-events-dlq.fifo --attribute-names ApproximateNumberOfMessages"
echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron"
[ ${FAIL} -eq 0 ] && exit 0 || exit 1
