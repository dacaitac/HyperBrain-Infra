"""Notion webhook receiver — pure protocol adapter (ADR-011, issue #41).

Verifies X-Notion-Signature (HMAC-SHA256 of the raw body, keyed with the
subscription verification token), wraps the payload with source_system=NOTION
and publishes it to sync-events.fifo. All Notion -> domain mapping stays in
the Core consumer (HU-14).
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
_secret_cache: str | None = None


def _webhook_secret() -> str:
    """Dev: NOTION_WEBHOOK_SECRET env var. Prod: SSM SecureString (name in
    WEBHOOK_SECRET_PARAM) so the secret never lands in Terraform state."""
    global _secret_cache
    if _secret_cache is None:
        direct = os.environ.get("NOTION_WEBHOOK_SECRET")
        if direct:
            _secret_cache = direct
        else:
            ssm = boto3.client("ssm")
            param = os.environ["WEBHOOK_SECRET_PARAM"]
            _secret_cache = ssm.get_parameter(Name=param, WithDecryption=True)["Parameter"]["Value"]
    return _secret_cache


def _signature_valid(body: str, header: str | None) -> bool:
    if not header:
        return False
    expected = "sha256=" + hmac.new(_webhook_secret().encode(), body.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def lambda_handler(event, _context):
    body = event.get("body") or ""
    payload = json.loads(body) if body else {}

    # One-time subscription handshake: Notion POSTs the verification_token
    # before any signed delivery. Log it so it can be stored as the secret (#42).
    if "verification_token" in payload:
        logger.info("Notion subscription verification_token received: %s", payload["verification_token"])
        return {"statusCode": 200, "body": "ok"}

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not _signature_valid(body, headers.get("x-notion-signature")):
        # Distinguish unsigned senders (e.g. Notion DB automations, which never
        # sign) from real signature mismatches; never log the signature value.
        reason = "missing header" if "x-notion-signature" not in headers else "signature mismatch"
        source = payload.get("source") or {}
        logger.warning(
            "Rejected webhook delivery (%s): type=%s source_type=%s user_agent=%s",
            reason, payload.get("type"), source.get("type"), headers.get("user-agent"))
        return {"statusCode": 401, "body": "invalid signature"}

    message_id = payload.get("id") or str(uuid.uuid4())
    envelope = {
        "source_system": "NOTION",
        "message_id": message_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload": payload,
    }
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(envelope),
        MessageGroupId=(payload.get("entity") or {}).get("id") or "notion",
        MessageDeduplicationId=message_id,
    )
    logger.info("Forwarded Notion webhook %s to sync-events.fifo", message_id)
    return {"statusCode": 200, "body": "ok"}
