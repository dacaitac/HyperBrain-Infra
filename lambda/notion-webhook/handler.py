"""Notion webhook receiver — pure protocol adapter (ADR-011, issues #41/#42).

Authenticates a delivery through one of two channels, then wraps the payload
with source_system=NOTION and publishes it to sync-events.fifo. All Notion ->
domain mapping stays in the Core consumer (HU-14).

- Integration subscription: signed with X-Notion-Signature (HMAC-SHA256 of the
  raw body, keyed with the subscription verification token).
- Database automation: Notion automations cannot sign, so they authenticate
  with a shared bearer secret in the X-HyperBrain-Token header (ADR-011 v1.2.0).

Unverifiable deliveries are dropped but answered 200: Notion pauses senders
whose endpoint keeps failing, and a protocol adapter must never take the
channel down (a stale key mid-rotation would otherwise kill the subscription).
Drops stay visible as WARNINGs in CloudWatch.
"""

import hashlib
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
    """Resolve a shared secret, cached per container. Dev: read it straight
    from ``env_var``. Prod: read the SSM SecureString whose name is in
    ``param_env`` so the value never lands in Terraform state."""
    if env_var not in _secret_cache:
        direct = os.environ.get(env_var)
        if direct:
            _secret_cache[env_var] = direct
        else:
            ssm = boto3.client("ssm")
            name = os.environ[param_env]
            _secret_cache[env_var] = ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
    return _secret_cache[env_var]


def _signature_valid(body: str, header: str | None) -> bool:
    if not header:
        return False
    secret = _secret("NOTION_WEBHOOK_SECRET", "WEBHOOK_SECRET_PARAM")
    expected = "sha256=" + hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def _automation_token_valid(header: str | None) -> bool:
    if not header:
        return False
    return hmac.compare_digest(_secret("NOTION_AUTOMATION_TOKEN", "AUTOMATION_TOKEN_PARAM"), header)


def _forward(body: str, payload: dict, channel: str) -> dict:
    message_id = payload.get("id") or str(uuid.uuid4())
    envelope = {
        "source_system": "NOTION",
        "message_id": message_id,
        "delivery_channel": channel,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload": payload,
    }
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(envelope),
        MessageGroupId=(payload.get("entity") or {}).get("id") or "notion",
        MessageDeduplicationId=message_id,
    )
    logger.info("Forwarded Notion webhook %s (%s) to sync-events.fifo", message_id, channel)
    return {"statusCode": 200, "body": "ok"}


def lambda_handler(event, _context):
    body = event.get("body") or ""
    payload = json.loads(body) if body else {}

    # One-time subscription handshake: Notion POSTs the verification_token
    # before any signed delivery. Log it so it can be stored as the secret (#42).
    if "verification_token" in payload:
        logger.info("Notion subscription verification_token received: %s", payload["verification_token"])
        return {"statusCode": 200, "body": "ok"}

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if _signature_valid(body, headers.get("x-notion-signature")):
        return _forward(body, payload, "subscription")
    if _automation_token_valid(headers.get("x-hyperbrain-token")):
        return _forward(body, payload, "automation")

    # Unverified: drop but answer 200 so the sender is never paused. Never log
    # the signature or token; only the metadata needed to triage.
    source = payload.get("source") or {}
    logger.warning(
        "Dropped unverified webhook delivery: type=%s source_type=%s user_agent=%s",
        payload.get("type"), source.get("type"), headers.get("user-agent"))
    return {"statusCode": 200, "body": "ignored"}
