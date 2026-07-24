#!/usr/bin/env bash
# Prod E2E smoke test for the replan-agenda Lambda (HU-01b, issue #66).
# Fires two requests at the Function URL: one with a valid token (expects 200
# with body "ok") and one with a wrong token (expects 200 with body "ignored").
# Follow-up (manual): confirm the command_id appears in Core logs on
# daniel-ubuntu and user-commands-dlq.fifo stays empty.
# Requires: aws CLI with credentials that can read the SSM token and the
# Function URL (terraform output -raw function_url, or REPLAN_AGENDA_FUNCTION_URL).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
TOKEN_PARAM="${REPLAN_TOKEN_PARAM:-/hyperbrain/replan/token}"
URL="${REPLAN_AGENDA_FUNCTION_URL:-${1:-}}"
PASS=0; FAIL=0

check() { echo -n "  -> $1... "; }
ok()    { echo "OK"; PASS=$((PASS+1)); }
fail()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

if [ -z "${URL}" ]; then
  echo "Usage: $0 <function-url>  (or set REPLAN_AGENDA_FUNCTION_URL)"; exit 2
fi

echo "=== HyperBrain replan-agenda Lambda smoke test (AWS prod) ==="
echo "Function URL: ${URL}"

TOKEN=$(aws ssm get-parameter --region "${REGION}" --name "${TOKEN_PARAM}" \
  --with-decryption --query Parameter.Value --output text)

post() { # $1=extra header (X-HyperBrain-Token value, may be empty) → prints "<http_code> <body>"
  if [ -n "$1" ]; then
    curl -s -w '\n%{http_code}' -X POST "${URL}" \
      -H "X-HyperBrain-Token: $1"
  else
    curl -s -w '\n%{http_code}' -X POST "${URL}"
  fi
}

post_body() { # $1=token  $2=JSON body → prints "<http_code> <body>"
  curl -s -w '\n%{http_code}' -X POST "${URL}" \
    -H "X-HyperBrain-Token: $1" \
    -H "Content-Type: application/json" \
    -d "$2"
}

# Real Shortcut shape: {"data": "<double-encoded JSON string>"} → de-stringifies
# to {date, sample:[...]}, which the Lambda forwards as the command's `sleep`.
SLEEP_BODY='{"data":"{\"date\":\"23/07/2026 at 10:12 PM\",\"sample\":[{\"stage\":\"Core\",\"startDate\":\"22/07/2026 at 12:22 AM\",\"endDate\":\"22/07/2026 at 12:45 AM\",\"duration\":\"22:53\"},{\"stage\":\"REM\",\"startDate\":\"22/07/2026 at 1:48 AM\",\"endDate\":\"22/07/2026 at 2:19 AM\",\"duration\":\"31:21\"}]}"}'

check "Valid token, no body -> HTTP 200 ok (replan only)"
RESPONSE=$(post "${TOKEN}")
BODY=$(echo "${RESPONSE}" | head -n 1)
STATUS=$(echo "${RESPONSE}" | tail -n 1)
[ "${STATUS}" = "200" ] && [ "${BODY}" = "ok" ] && ok || fail "HTTP ${STATUS} body='${BODY}'"

check "Valid token + Shortcut sleep body -> HTTP 200 ok (replan + sleep forwarded)"
RESPONSE=$(post_body "${TOKEN}" "${SLEEP_BODY}")
BODY=$(echo "${RESPONSE}" | head -n 1)
STATUS=$(echo "${RESPONSE}" | tail -n 1)
[ "${STATUS}" = "200" ] && [ "${BODY}" = "ok" ] && ok || fail "HTTP ${STATUS} body='${BODY}'"

check "Wrong token -> HTTP 200 ignored (dropped, not forwarded)"
RESPONSE=$(post "wrong-token")
BODY=$(echo "${RESPONSE}" | head -n 1)
STATUS=$(echo "${RESPONSE}" | tail -n 1)
[ "${STATUS}" = "200" ] && [ "${BODY}" = "ignored" ] && ok || fail "HTTP ${STATUS} body='${BODY}'"

check "No token -> HTTP 200 ignored (dropped)"
RESPONSE=$(post "")
BODY=$(echo "${RESPONSE}" | head -n 1)
STATUS=$(echo "${RESPONSE}" | tail -n 1)
[ "${STATUS}" = "200" ] && [ "${BODY}" = "ignored" ] && ok || fail "HTTP ${STATUS} body='${BODY}'"

echo ""
echo "Verify REPLAN_AGENDA command reached the Core (check kubectl logs or daniel-ubuntu):"
echo "  kubectl logs deploy/hyperbrain-core | grep REPLAN_AGENDA"
echo "The Lambda logs '(sleep=attached|absent)' per request; the sleep-body call above should read 'attached'."
echo "Verify DLQ is empty:"
echo "  aws sqs get-queue-attributes --queue-url https://sqs.${REGION}.amazonaws.com/<account>/user-commands-dlq.fifo --attribute-names ApproximateNumberOfMessages"
echo ""
echo "Result: ${PASS} passed, ${FAIL} failed"
[ ${FAIL} -eq 0 ] && exit 0 || exit 1
