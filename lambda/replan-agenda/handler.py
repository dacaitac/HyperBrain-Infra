"""Replan Agenda command gateway — pure protocol adapter (HU-01b, issue #66).

Validates the bearer token in the X-HyperBrain-Token header against an SSM
SecureString, then publishes a REPLAN_AGENDA command to user-commands.fifo.
The Core UserCommandsConsumer picks it up and triggers the Prioritizer +
Planner pipeline.

No request body is required — the command carries only the command_id and
occurred_at generated here. Any body sent by the caller is silently ignored.

Unverifiable requests are dropped but answered 200: same defensive pattern as
the other Lambda adapters. Drops are visible as WARNINGs in CloudWatch.
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
        _secret("REPLAN_TOKEN", "TOKEN_PARAM"), header
    )


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
        "type": "REPLAN_AGENDA",
        "command_id": command_id,
        "occurred_at": occurred_at,
    }
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=json.dumps(command),
        MessageGroupId="user-commands",
        MessageDeduplicationId=command_id,
    )
    logger.info("Published REPLAN_AGENDA command %s to user-commands.fifo", command_id)
    return {"statusCode": 200, "body": "ok"}
