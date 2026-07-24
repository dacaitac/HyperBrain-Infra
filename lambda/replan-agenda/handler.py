"""Replan Agenda command gateway — pure protocol adapter (HU-01b, issue #66).

Validates the bearer token in the X-HyperBrain-Token header against an SSM
SecureString, then publishes a REPLAN_AGENDA command to user-commands.fifo.
The Core UserCommandsConsumer picks it up and triggers the Prioritizer +
Planner pipeline.

No request body is required. When present, an optional sleep payload is
forwarded verbatim on the command so the Planner can factor last night's
HealthKit sleep into the replan. The bridge is provisional: a free Apple
account cannot read HealthKit from the first-party app, but an iOS Shortcut
can read Health and POST the sleep payload here.

The Shortcut sends ``{"data": "<double-encoded JSON string>"}`` where the
string de-stringifies to ``{"date": ..., "sample": [...]}``. This adapter only
undoes that transport double-encoding and forwards the resulting object as the
command's `sleep`; a body that already carries a `sleep` object directly is
also accepted (fallback).

This adapter is pure protocol: it never interprets, validates or reshapes the
sleep payload (the Core reads it with a tolerant reader). A missing, empty, or
non-JSON body degrades silently to a replan-only command — the original
behaviour.

Unverifiable requests are dropped but answered 200: same defensive pattern as
the other Lambda adapters. Drops are visible as WARNINGs in CloudWatch.
"""

import base64
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
        _secret("REPLAN_TOKEN", "TOKEN_PARAM"), header
    )


def _sleep_from_body(event) -> object | None:
    """Best-effort extraction of the optional sleep payload from the request
    body. Pure protocol: the payload is forwarded verbatim — its shape is never
    interpreted or validated here (the Core reads it with a tolerant reader).
    Any parsing problem degrades silently to None, i.e. a replan-only command.

    The Shortcut wraps the payload as ``{"data": "<double-encoded JSON>"}``; the
    only transformation done here is undoing that transport double-encoding
    (``json.loads`` on the inner string). A body that already carries a `sleep`
    object directly is accepted as a fallback."""
    raw = event.get("body")
    if not raw:
        return None
    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(payload, dict):
        return None
    # Real Shortcut format: unwrap the double-encoded `data` string.
    data = payload.get("data")
    if isinstance(data, str):
        try:
            return json.loads(data)
        except (ValueError, TypeError):
            return None
    # Fallback: a body that already carries a `sleep` object directly.
    return payload.get("sleep")


def lambda_handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not _token_valid(headers.get("x-hyperbrain-token")):
        logger.warning(
            "Dropped unverified replan request: user-agent=%s",
            headers.get("user-agent"),
        )
        return {"statusCode": 200, "body": "ignored"}

    command_id = str(uuid.uuid4())
    occurred_at = datetime.now(timezone.utc).isoformat()
    command = {
        "command_type": "REPLAN_AGENDA",
        "command_id": command_id,
        "occurred_at": occurred_at,
    }
    sleep = _sleep_from_body(event)
    if sleep is not None:
        command["sleep"] = sleep
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(command),
        MessageGroupId="user-commands",
        MessageDeduplicationId=command_id,
    )
    logger.info(
        "Published REPLAN_AGENDA command %s to user-commands.fifo (sleep=%s)",
        command_id,
        "attached" if sleep is not None else "absent",
    )
    return {"statusCode": 200, "body": "ok"}
