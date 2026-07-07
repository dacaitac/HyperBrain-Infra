#!/usr/bin/env bash
# LocalStack smoke test for the Notion webhook Lambda (issues #41/#42).
# Deploys lambda/notion-webhook/handler.py into LocalStack and exercises both
# auth channels (HMAC subscription + X-HyperBrain-Token automation) plus the
# drop-but-200 behaviour. Requires: docker compose up -d (SERVICES=sqs,lambda).
set -euo pipefail

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SECRET="dev-webhook-secret"
AUTOMATION_TOKEN="dev-automation-token"
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

# Drain leftovers so the assertions below see only our messages
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
  --environment "Variables={NOTION_WEBHOOK_SECRET=${SECRET},NOTION_AUTOMATION_TOKEN=${AUTOMATION_TOKEN},QUEUE_URL=${QUEUE_URL}}" > /dev/null
awsl lambda wait function-active-v2 --function-name "${FN}"
ok

invoke() { # $1=body $2=notion-signature $3=hyperbrain-token → prints statusCode
  local event out
  event=$(python3 - "$1" "$2" "$3" <<'PY'
import json, sys
body, sig, token = sys.argv[1], sys.argv[2], sys.argv[3]
headers = {"content-type": "application/json"}
if sig:
    headers["x-notion-signature"] = sig
if token:
    headers["x-hyperbrain-token"] = token
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

# Assert the next message on the queue matches source_system=NOTION, the given
# delivery_channel and entity id.
assert_envelope() { # $1=expected-channel $2=expected-entity
  local msg
  msg=$(awsl sqs receive-message --queue-url "${QUEUE_URL}" \
    --wait-time-seconds 10 --max-number-of-messages 1 \
    --query 'Messages[0].Body' --output text 2>/dev/null || echo "None")
  if [ "${msg}" != "None" ] && python3 -c '
import json, sys
env = json.loads(sys.argv[1])
assert env["source_system"] == "NOTION", env
assert env["message_id"], env
assert env["delivery_channel"] == sys.argv[2], env
assert env["payload"]["entity"]["id"] == sys.argv[3], env
' "${msg}" "$1" "$2"; then ok; else fail "message missing or malformed: ${msg}"; fi
}

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "${SECRET}" -hex | awk '{print $NF}'; }

SUB_BODY='{"id":"sub-'"$(date +%s)"'","type":"page.content_updated","entity":{"id":"sub-entity","type":"page"},"data":{"source":"localstack-smoke-test"}}'
AUTO_BODY='{"id":"auto-'"$(date +%s)"'","type":"automation","entity":{"id":"auto-entity","type":"page"},"data":{"source":"localstack-smoke-test"}}'

# ── Subscription channel (HMAC) ────────────────────────────────────────────────
check "Signed subscription event → HTTP 200"
STATUS=$(invoke "${SUB_BODY}" "sha256=$(sign "${SUB_BODY}")" "")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Subscription envelope on queue (delivery_channel=subscription)"
assert_envelope "subscription" "sub-entity"

# ── Automation channel (bearer token) ──────────────────────────────────────────
check "Automation event with valid X-HyperBrain-Token → HTTP 200"
STATUS=$(invoke "${AUTO_BODY}" "" "${AUTOMATION_TOKEN}")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Automation envelope on queue (delivery_channel=automation)"
assert_envelope "automation" "auto-entity"

# ── Unverified deliveries: dropped but answered 200 (never pause the sender) ────
check "No signature, no token → HTTP 200 (dropped, not forwarded)"
STATUS=$(invoke "${AUTO_BODY}" "" "")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Wrong automation token → HTTP 200 (dropped)"
STATUS=$(invoke "${AUTO_BODY}" "" "wrong-token")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Tampered signature → HTTP 200 (dropped)"
STATUS=$(invoke "${SUB_BODY}" "sha256=deadbeef" "")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

check "Dropped deliveries left the queue empty"
EMPTY=$(awsl sqs receive-message --queue-url "${QUEUE_URL}" \
  --wait-time-seconds 3 --query 'Messages[0].Body' --output text 2>/dev/null || echo "None")
[ "${EMPTY}" = "None" ] && ok || fail "unexpected message forwarded: ${EMPTY}"

# ── Handshake ──────────────────────────────────────────────────────────────────
check "Subscription verification_token → HTTP 200 (unsigned handshake)"
STATUS=$(invoke '{"verification_token":"smoke-verification-token"}' "" "")
[ "${STATUS}" = "200" ] && ok || fail "statusCode=${STATUS}"

echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron"
[ ${FAIL} -eq 0 ] && echo "✓ Lambda notion-webhook operativa en LocalStack" && exit 0 \
                  || { echo "✗ Revisar logs: docker compose logs localstack"; exit 1; }
