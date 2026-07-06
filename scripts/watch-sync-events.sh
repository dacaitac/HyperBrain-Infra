#!/usr/bin/env bash
# Tails the HyperBrain-core logs, filtered to inbound Apple sync events.
# Run on daniel-ubuntu to watch reminders/events flow in from SentinelAPI while you
# create/edit/delete a reminder on the Mac. One line per arrived event:
#
#   sync event received: REMINDER CREATED entityId=... eventId=...
#
# Prerequisite: the core must be consuming the REAL sync-events.fifo (SentinelAPI only ever
# publishes to real AWS). Point it there via .env before `docker compose up -d hyperbrain-core`:
#   AWS_ACCESS_KEY_ID=<core key>   AWS_SECRET_ACCESS_KEY=<core secret>
#   AWS_DEFAULT_REGION=us-east-1   AWS_SQS_ENDPOINT_OVERRIDE=https://sqs.us-east-1.amazonaws.com
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$COMPOSE_DIR"

echo "Watching hyperbrain-core for inbound sync events (Ctrl-C to stop)..."
docker compose logs -f --no-log-prefix hyperbrain-core 2>&1 | grep --line-buffered "sync event received"
