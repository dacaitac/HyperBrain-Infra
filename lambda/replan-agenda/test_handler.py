"""Local unit tests for the replan-agenda Lambda handler (HU-01b, issue #66).

Runs with the standard library only — no AWS, no boto3 install required. `boto3`
is stubbed in ``sys.modules`` before importing the handler, and the fake SQS
client captures every published message so the command envelope can be asserted.

    python3 lambda/replan-agenda/test_handler.py

Covers the sleep-forwarding contract: the real Shortcut body
``{"data": "<double-encoded JSON>"}`` is un-nested and forwarded verbatim as the
command's `sleep`; a body that already carries a `sleep` object directly is
accepted as a fallback; and a missing / empty / non-JSON body degrades to a
replan-only command. The token drop path and the FIFO routing keys are pinned.

Set ``SLEEP_SAMPLE_JSON`` to the captured Shortcut body to also exercise the
real payload (otherwise that one case is skipped).
"""

import base64
import json
import os
import sys
import types
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


class _FakeSqs:
    def __init__(self):
        self.sent = []

    def send_message(self, **kwargs):
        self.sent.append(kwargs)
        return {"MessageId": "fake-message-id"}


_FAKE_SQS = _FakeSqs()


def _fake_client(service, *_args, **_kwargs):
    if service == "sqs":
        return _FAKE_SQS
    raise AssertionError(f"unexpected boto3 client requested: {service}")


# Stub boto3 before importing the handler: the module builds an sqs client at
# import time and would otherwise need the real dependency and AWS credentials.
_boto3_stub = types.ModuleType("boto3")
_boto3_stub.client = _fake_client
sys.modules["boto3"] = _boto3_stub

os.environ["QUEUE_URL"] = "https://sqs.test/user-commands.fifo"
os.environ["REPLAN_TOKEN"] = "test-token"  # read directly, bypassing SSM

import handler  # noqa: E402  (import after the boto3 stub / env are in place)

_VALID = {"x-hyperbrain-token": "test-token"}


def _event(headers=None, body=None, is_b64=False):
    event = {"headers": headers or {}}
    if body is not None:
        event["body"] = body
    if is_b64:
        event["isBase64Encoded"] = True
    return event


class ReplanHandlerTest(unittest.TestCase):
    def setUp(self):
        _FAKE_SQS.sent.clear()

    def _only_command(self):
        self.assertEqual(len(_FAKE_SQS.sent), 1)
        msg = _FAKE_SQS.sent[0]
        self.assertEqual(msg["MessageGroupId"], "user-commands")
        body = json.loads(msg["MessageBody"])
        self.assertEqual(body["command_type"], "REPLAN_AGENDA")
        # DedupId is the generated command_id.
        self.assertEqual(msg["MessageDeduplicationId"], body["command_id"])
        self.assertIn("occurred_at", body)
        return body

    # --- token gate ---------------------------------------------------------
    def test_missing_token_is_dropped(self):
        resp = handler.lambda_handler(_event(), None)
        self.assertEqual(resp, {"statusCode": 200, "body": "ignored"})
        self.assertEqual(_FAKE_SQS.sent, [])

    def test_wrong_token_is_dropped(self):
        resp = handler.lambda_handler(_event({"x-hyperbrain-token": "nope"}), None)
        self.assertEqual(resp, {"statusCode": 200, "body": "ignored"})
        self.assertEqual(_FAKE_SQS.sent, [])

    # --- replan-only (no sleep) ---------------------------------------------
    def test_no_body_replan_only(self):
        resp = handler.lambda_handler(_event(_VALID), None)
        self.assertEqual(resp, {"statusCode": 200, "body": "ok"})
        self.assertNotIn("sleep", self._only_command())

    def test_empty_body_replan_only(self):
        handler.lambda_handler(_event(_VALID, body=""), None)
        self.assertNotIn("sleep", self._only_command())

    def test_non_json_body_replan_only(self):
        handler.lambda_handler(_event(_VALID, body="not-json{"), None)
        self.assertNotIn("sleep", self._only_command())

    def test_json_without_sleep_key_replan_only(self):
        handler.lambda_handler(_event(_VALID, body=json.dumps({"foo": 1})), None)
        self.assertNotIn("sleep", self._only_command())

    def test_json_array_body_replan_only(self):
        handler.lambda_handler(_event(_VALID, body=json.dumps([1, 2, 3])), None)
        self.assertNotIn("sleep", self._only_command())

    # --- real Shortcut format: {"data": "<double-encoded JSON>"} -------------
    def test_data_double_encoded_forwarded_unnested(self):
        # The Shortcut sends {"data": "<json string>"}; the inner string
        # de-stringifies to {date, sample:[...]} and becomes the command sleep.
        sleep = {
            "date": "23/07/2026 at 10:12 PM",
            "sample": [
                {"stage": "Core", "startDate": "22/07/2026 at 12:22 AM",
                 "endDate": "22/07/2026 at 12:45 AM", "duration": "22:53"},
                {"stage": "Deep", "startDate": "22/07/2026 at 12:45 AM",
                 "endDate": "22/07/2026 at 12:50 AM", "duration": "5:28"},
                {"stage": "REM", "startDate": "22/07/2026 at 1:48 AM",
                 "endDate": "22/07/2026 at 2:19 AM", "duration": "31:21"},
            ],
        }
        body = json.dumps({"data": json.dumps(sleep)})  # double-encoded
        handler.lambda_handler(_event(_VALID, body=body), None)
        published = self._only_command()["sleep"]
        # Forwarded verbatim AND un-nested (a dict, not a string).
        self.assertEqual(published, sleep)
        self.assertIsInstance(published, dict)

    def test_data_from_reference_sample(self):
        # Exercise the exact captured Shortcut body if the reference is present.
        ref = os.environ.get("SLEEP_SAMPLE_JSON")
        if not ref or not os.path.exists(ref):
            self.skipTest("reference sample not available")
        with open(ref, encoding="utf-8") as fh:
            # The scratchpad file is a JSON fragment (no outer braces); wrap it.
            capture = json.loads("{" + fh.read() + "}")
        raw_data = capture["body"]["data"]
        handler.lambda_handler(_event(_VALID, body=json.dumps({"data": raw_data})), None)
        published = self._only_command()["sleep"]
        self.assertEqual(published, json.loads(raw_data))
        self.assertIn("sample", published)

    def test_malformed_data_string_replan_only(self):
        handler.lambda_handler(_event(_VALID, body=json.dumps({"data": "not-json{"})), None)
        self.assertNotIn("sleep", self._only_command())

    def test_data_from_base64_body(self):
        sleep = {"date": "23/07/2026 at 10:12 PM", "sample": [{"stage": "REM"}]}
        inner = json.dumps({"data": json.dumps(sleep)})
        raw = base64.b64encode(inner.encode()).decode()
        handler.lambda_handler(_event(_VALID, body=raw, is_b64=True), None)
        self.assertEqual(self._only_command()["sleep"], sleep)

    # --- fallback: body already carries a `sleep` object directly ------------
    def test_direct_sleep_object_forwarded_verbatim(self):
        sleep = {"date": "23/07/2026", "sample": [{"stage": "Core"}]}
        handler.lambda_handler(_event(_VALID, body=json.dumps({"sleep": sleep})), None)
        self.assertEqual(self._only_command()["sleep"], sleep)

    def test_sleep_shape_not_validated(self):
        # Pure protocol: an unexpected shape is forwarded untouched, not rejected.
        weird = {"foo": "bar", "nested": {"x": [1, 2]}}
        handler.lambda_handler(_event(_VALID, body=json.dumps({"sleep": weird})), None)
        self.assertEqual(self._only_command()["sleep"], weird)

    def test_null_sleep_is_omitted(self):
        handler.lambda_handler(_event(_VALID, body=json.dumps({"sleep": None})), None)
        self.assertNotIn("sleep", self._only_command())


if __name__ == "__main__":
    unittest.main(verbosity=2)
