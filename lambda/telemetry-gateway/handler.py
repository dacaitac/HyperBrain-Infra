"""Telemetry Gateway — pure protocol adapter (ADR-016, ADR-014, issue #59).

Validates the bearer token in the X-HyperBrain-Token header against an SSM
SecureString, then forwards the raw request body VERBATIM to telemetry-events
(standard queue). The body IS the TelemetryEnvelope JSON produced by the iOS
app: the gateway treats it as an opaque payload — it neither parses nor
reshapes it (raw-first ingestion, ADR-016). All domain interpretation stays in
the Core telemetry consumer.

Unverifiable requests are dropped but answered 200: same defensive pattern as
the other Lambda adapters. Drops are visible as WARNINGs in CloudWatch.
"""

import hmac
import logging
import os

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
        _secret("TELEMETRY_TOKEN", "TELEMETRY_TOKEN_PARAM"), header
    )


def lambda_handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not _token_valid(headers.get("x-hyperbrain-token")):
        logger.warning(
            "Dropped unverified telemetry request: user-agent=%s",
            headers.get("user-agent"),
        )
        return {"statusCode": 200, "body": "ignored"}

    # Opaque payload: forward the raw TelemetryEnvelope verbatim (raw-first).
    body = event.get("body") or ""
    _sqs.send_message(
        QueueUrl=os.environ["QUEUE_URL"],
        MessageBody=body,
    )
    logger.info(
        "Forwarded telemetry envelope (%d bytes) to telemetry-events", len(body)
    )
    return {"statusCode": 200, "body": "ok"}
