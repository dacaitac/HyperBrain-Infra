#!/usr/bin/env bash
# LocalStack smoke test for the Notion webhook Lambda (issue #41, CA-4).
# Deploys lambda/notion-webhook/handler.py into LocalStack, invokes it with a
# synthetic signed Function URL event and verifies the envelope reaches the
# local sync-events.fifo. Requires: docker compose up -d (SERVICES=sqs,lambda).
set -euo pipefail

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SECRET="dev-webhook-secret"
FN="notion-webhook-receiver"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

awsl() { aws --endpoint-url "${ENDPOINT}" --region "${REGION}" "$@"; }
check() { echo -n "  → $1... "; }
ok()    { echo "✓"; PASS=$((PASS+1)); }
fail()  { echo "✗  $1"; FAIL=$((FAIL+1)); }

echo "=== HyperBrain Notion webhook Lambda smoke test (LocalStack) ==="

QUEUE_URL=$(awsl sqs get-queue-url --queue-name sync-events.fifo --query QueueUrl --output text)

# Drain leftovers so the assertion below sees only our message
while true; do
  RECEIPT=$(awsl sqs receive-message --queue-url "${QUEUE_URL}" \
    --query 'Messages[0].ReceiptHandle' --output text 2>/dev/null || echo "None")
  if [ "${RECEIPT}" = "None" ] || [ -z "${RECEIPT}" ]; then break; fi
  awsl sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${RECEIPT}"
done

check "Package and deploy Lambda to LocalStack"
ZIP="$(mktemp -d)/handler.zip"
(cd "${DIR}/lambda/notion-webhook" && zip -q -j "${ZIP}" handler.py)
awsl lambda delete-function --function-name "${FN}" > /dev/null 2>&1 || true
awsl lambda create-function \
  --function-name "${FN}" \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --zip-file "fileb://${ZIP}" \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --timeout 30 \
  --environment "Variables={NOTION_WEBHOOK_SECRET=${SECRET},QUEUE_URL=${QUEUE_URL}}" > /dev/null
awsl lambda wait function-active-v2 --function-name "${FN}"
ok

invoke() { # $1=body $2=signature-header → prints statusCode
  local event out
  event=$(python3 - "$1" "$2" <<'PY'
import json, sys
body, sig = sys.argv[1], sys.argv[2]
headers = {"content-type": "application/json"}
if sig:
    headers["x-notion-signature"] = sig
print(json.dumps({"headers": headers, "body": body,
                  "requestContext": {"http": {"method": "POST"}}}))
PY
)
  out="$(mktemp)"
  awsl lambda invoke --function-name "${FN}" \
    --cli-binary-format raw-in-base64-out \
    --payload "${event}" "${out}" > /dev/null
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('statusCode'))" "${out}"
}

BODY='{"id":"smoke-'"$(date +%s)"'","type":"page.content_updated","entity":{"id":"smoke-entity","type":"page"},"data":{"source":"localstack-smoke-test"}}'
SIG="sha256=$(printf '%s' "${BODY}" | openssl dgst -sha256 -hmac "${SECRET}" -hex | awk '{print $NF}')"

check "Signed synthetic event → HTTP 200"
STATUS=$(invoke "${BODY}" "${SIG}")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Envelope arrives at sync-events.fifo with source_system=NOTION"
MSG=$(awsl sqs receive-message --queue-url "${QUEUE_URL}" \
  --wait-time-seconds 10 --max-number-of-messages 1 \
  --query 'Messages[0].Body' --output text 2>/dev/null || echo "None")
if [ "${MSG}" != "None" ] && python3 -c '
import json, sys
env = json.loads(sys.argv[1])
assert env["source_system"] == "NOTION", env
assert env["message_id"], env
assert env["payload"]["entity"]["id"] == "smoke-entity", env
' "${MSG}"; then ok; else fail "message missing or malformed: ${MSG}"; fi

check "Invalid signature → HTTP 401"
STATUS=$(invoke "${BODY}" "sha256=deadbeef")
[ "${STATUS}" = "401" ] && ok || fail "statusCode=${STATUS}"

check "Missing signature → HTTP 401"
STATUS=$(invoke "${BODY}" "")
[ "${STATUS}" = "401" ] && ok || fail "statusCode=${STATUS}"

check "Subscription verification_token → HTTP 200 (unsigned handshake)"
STATUS=$(invoke '{"verification_token":"smoke-verification-token"}' "")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron"
[ ${FAIL} -eq 0 ] && echo "✓ Lambda notion-webhook operativa en LocalStack" && exit 0 \
                  || { echo "✗ Revisar logs: docker compose logs localstack"; exit 1; }
