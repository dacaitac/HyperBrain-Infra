"""Messaging Gateway — protocol adapter for OpenClaw/WhatsApp (ADR-014).

Pure protocol adapter: validates the bearer token, wraps the payload with
source_system metadata and publishes to sync-events.fifo. All domain
mapping stays in the Core consumer.

Auth: bearer token in X-HyperBrain-Token header (SSM SecureString).
Source: X-Source-System header (default: OPENCLAW).
Unverifiable deliveries are dropped but answered 200 to avoid sender pauses.
Drops are visible as WARNINGs in CloudWatch.
"""

import hmac
import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_sqs = boto3.client("sqs")
_secret_cache: dict[str, str] = {}


def _secret(env_var: str, param_env: str) -> str:
    """Resolve a shared secret, cached per container. Dev: read directly
    from ``env_var``. Prod: read the SSM SecureString whose name is in
    ``param_env`` so the value never lands in Terraform state."""
    if env_var not in _secret_cache:
        direct = os.environ.get(env_var)
        if direct:
            _secret_cache[env_var] = direct
        else:
            ssm = boto3.client("ssm")
            name = os.environ[param_env]
            _secret_cache[env_var] = ssm.get_parameter(
                Name=name, WithDecryption=True
            )["Parameter"]["Value"]
    return _secret_cache[env_var]


def _token_valid(header: str | None) -> bool:
    if not header:
        return False
    return hmac.compare_digest(
        _secret("MESSAGING_TOKEN", "MESSAGING_TOKEN_PARAM"), header
    )


def _forward(payload: dict, source_system: str) -> dict:
    message_id = str(payload.get("id") or uuid.uuid4())
    envelope = {
        "source_system": source_system,
        "message_id": message_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload": payload,
    }
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(envelope),
        # Group by conversation so messages within a session are ordered.
        MessageGroupId=str(payload.get("conversation_id") or message_id),
        MessageDeduplicationId=message_id,
    )
    logger.info("Forwarded %s message %s to sync-events.fifo", source_system, message_id)
    return {"statusCode": 200, "body": "ok"}


def lambda_handler(event, _context):
    body = event.get("body") or ""
    payload = json.loads(body) if body else {}
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not _token_valid(headers.get("x-hyperbrain-token")):
        logger.warning(
            "Dropped unverified delivery: user-agent=%s",
            headers.get("user-agent"),
        )
        return {"statusCode": 200, "body": "ignored"}

    source_system = headers.get("x-source-system", "OPENCLAW").upper()
    return _forward(payload, source_system)
