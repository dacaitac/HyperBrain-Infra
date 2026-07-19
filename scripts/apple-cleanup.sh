#!/usr/bin/env bash
# =============================================================================
# apple-cleanup.sh — F5' cleanup gate, Apple side (ADR-021)
#
# Deletes HyperBrain-controllable items via the SentinelAPI REST contract:
#   1. ALL reminders (every reminder list lives in iCloud and is HyperBrain's
#      write surface)
#   2. Calendar events ONLY in allowed calendars. The live API contract
#      (verified 2026-07-18 against GET /calendars + /openapi.yaml) exposes
#      {title, source_name, color, is_default} — there is NO
#      allowsContentModifications field on the wire. Exclusion is therefore:
#        - every calendar whose source_name != "iCloud" (Google/Other sources
#          are externally-owned AGENDA-role calendars per ADR-009, and Google
#          resurrects deletes anyway), PLUS
#        - any title listed in AGENDA_CALENDARS (comma-separated, optional)
#
# Does NOT delete calendars or reminder lists themselves.
# Does NOT purge SQS (scripts/k8s/purge-sqs.sh) nor touch the SentinelAPI
# snapshot (/resync) — the hub orchestrates the full gate sequence.
#
# Idempotent: HTTP 404 on DELETE is counted as already-deleted.
#
# Usage:
#   scripts/apple-cleanup.sh              # DRY-RUN (default): only reports
#   scripts/apple-cleanup.sh --execute    # actually deletes
#
# Env:
#   SENTINEL_API_URL   default http://100.74.180.105:8080 (Mac Mini, tailnet)
#   AGENDA_CALENDARS   extra iCloud calendar titles to protect, comma-separated
# =============================================================================
set -euo pipefail

BASE_URL="${SENTINEL_API_URL:-http://100.74.180.105:8080}"
AGENDA_CALENDARS="${AGENDA_CALENDARS:-}"
MODE="dry-run"
[[ "${1:-}" == "--execute" ]] && MODE="execute"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }

log() { echo "[apple-cleanup] $*"; }
enc() { jq -rn --arg v "$1" '$v|@uri'; }

# DELETE helper -> echoes outcome: deleted | gone | failed:<code>
del() { # $1 = path with raw id already encoded
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "${BASE_URL}$1")"
  case "${code}" in
    200|204) echo "deleted" ;;
    404)     echo "gone" ;;
    *)       echo "failed:${code}" ;;
  esac
}

log "SentinelAPI: ${BASE_URL} — mode: ${MODE}"
curl -sf --max-time 10 "${BASE_URL}/health" >/dev/null \
  || { echo "ERROR: SentinelAPI unreachable at ${BASE_URL}" >&2; exit 1; }

# ── 1. Reminders ─────────────────────────────────────────────────────────────
reminders_json="$(curl -sf "${BASE_URL}/reminders")"
# ids are UUIDs / EventKit identifiers without whitespace: word-splitting is safe
# (macOS ships bash 3.2 — no mapfile)
reminder_ids="$(jq -r '.[].id' <<<"${reminders_json}")"
reminder_count="$(grep -c . <<<"${reminder_ids}" || true)"
log "reminders found: ${reminder_count}"

r_deleted=0; r_gone=0; r_failed=0
for id in ${reminder_ids}; do
  title="$(jq -r --arg id "$id" '.[] | select(.id==$id) | .payload.title' <<<"${reminders_json}")"
  if [[ "${MODE}" == "dry-run" ]]; then
    log "  would delete reminder: ${title} (${id})"
    continue
  fi
  case "$(del "/reminders/$(enc "${id}")")" in
    deleted)  r_deleted=$((r_deleted+1)) ;;
    gone)     r_gone=$((r_gone+1)); log "  already gone: ${id}" ;;
    failed:*) r_failed=$((r_failed+1)); log "  FAILED delete reminder ${title} (${id})" ;;
  esac
done

# ── 2. Calendars: build the allowed set ──────────────────────────────────────
calendars_json="$(curl -sf "${BASE_URL}/calendars")"
IFS=',' read -r -a agenda_titles <<<"${AGENDA_CALENDARS}"
agenda_json="$(printf '%s\n' "${agenda_titles[@]:-}" | jq -R . | jq -s 'map(select(length>0))')"

allowed_ids_json="$(jq --argjson agenda "${agenda_json}" \
  '[ .[] | select(.payload.source_name == "iCloud")
        | select((.payload.title as $t | $agenda | index($t)) | not)
        | .id ]' <<<"${calendars_json}")"

log "calendars:"
jq -r --argjson allowed "${allowed_ids_json}" \
  '.[] | "  \(if (.id as $i | $allowed | index($i)) then "ALLOWED " else "EXCLUDED" end) \(.payload.title) [\(.payload.source_name)] (\(.id))"' \
  <<<"${calendars_json}"

# ── 3. Events in allowed calendars ───────────────────────────────────────────
events_json="$(curl -sf "${BASE_URL}/events")"
total_events="$(jq 'length' <<<"${events_json}")"
event_ids="$(jq -r --argjson allowed "${allowed_ids_json}" \
  '.[] | select(.payload.calendar_id as $c | $allowed | index($c)) | .id' <<<"${events_json}")"
event_count="$(grep -c . <<<"${event_ids}" || true)"
log "events found: ${total_events} — in allowed calendars: ${event_count}"

e_deleted=0; e_gone=0; e_failed=0
for id in ${event_ids}; do
  title="$(jq -r --arg id "$id" '.[] | select(.id==$id) | .payload.title' <<<"${events_json}")"
  cal="$(jq -r --arg id "$id" '.[] | select(.id==$id) | .payload.calendar_name' <<<"${events_json}")"
  if [[ "${MODE}" == "dry-run" ]]; then
    log "  would delete event: ${title} @ ${cal} (${id})"
    continue
  fi
  case "$(del "/events/$(enc "${id}")")" in
    deleted)  e_deleted=$((e_deleted+1)) ;;
    gone)     e_gone=$((e_gone+1)); log "  already gone: ${id}" ;;
    failed:*) e_failed=$((e_failed+1)); log "  FAILED delete event ${title} (${id})" ;;
  esac
done

# ── Summary ──────────────────────────────────────────────────────────────────
skipped_events=$((total_events - event_count))
echo
log "===== summary (${MODE}) ====="
if [[ "${MODE}" == "dry-run" ]]; then
  log "reminders to delete: ${reminder_count}"
  log "events to delete:    ${event_count} (skipped in excluded calendars: ${skipped_events})"
  log "re-run with --execute to apply"
else
  log "reminders: deleted=${r_deleted} already-gone=${r_gone} failed=${r_failed}"
  log "events:    deleted=${e_deleted} already-gone=${e_gone} failed=${e_failed} skipped=${skipped_events}"
  [[ $((r_failed + e_failed)) -eq 0 ]] || { log "COMPLETED WITH FAILURES"; exit 1; }
fi
