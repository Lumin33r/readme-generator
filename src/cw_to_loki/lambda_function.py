"""
CloudWatch Logs → Loki forwarder.

Triggered by CloudWatch Logs subscription filters.
Each invocation receives a gzip+base64 encoded log batch, decodes it,
and pushes the entries to Loki's HTTP push API.
"""
import base64
import gzip
import json
import os
import urllib.request
import urllib.error
from urllib.parse import urlparse

LOKI_ENDPOINT = os.environ["LOKI_PUSH_URL"]  # e.g. http://<nlb>:3100/loki/api/v1/push


def handler(event, context):
    # Decode the CloudWatch Logs payload (base64 → gzip → JSON)
    compressed = base64.b64decode(event["awslogs"]["data"])
    payload = json.loads(gzip.decompress(compressed))

    log_group  = payload["logGroup"]
    log_stream = payload["logStream"]

    # Build Loki stream labels from the log group name
    labels = {
        "job":        _job_label(log_group),
        "log_group":  log_group,
        "log_stream": log_stream,
    }
    label_str = "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"

    # Convert CW log events to Loki log values [timestamp_ns, line]
    values = []
    for event_record in payload.get("logEvents", []):
        ts_ns = str(event_record["timestamp"] * 1_000_000)  # ms → ns
        values.append([ts_ns, event_record["message"]])

    if not values:
        return

    body = json.dumps({
        "streams": [{"stream": labels, "values": values}]
    }).encode()

    req = urllib.request.Request(
        LOKI_ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status not in (200, 204):
                raise RuntimeError(f"Loki returned HTTP {resp.status}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Loki push failed: {exc.code} {exc.reason}") from exc


def _job_label(log_group: str) -> str:
    """Derives a short job label from a CloudWatch log group path."""
    # /aws/lambda/ReadmeGeneratorAgentInvoker → readme-generator-agent-invoker
    # /aws/states/ReadmeGeneratorPipeline     → readme-generator-sfn
    mapping = {
        "/aws/lambda/ReadmeGeneratorAgentInvoker": "readme-generator-agent-invoker",
        "/aws/lambda/ReadmeGeneratorParseS3Event":  "readme-generator-parse-s3-event",
        "/aws/states/ReadmeGeneratorPipeline":      "readme-generator-sfn",
    }
    return mapping.get(log_group, log_group.lstrip("/").replace("/", "-"))
