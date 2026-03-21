"""
Agent trajectory tests — verify the Step Functions execution followed the
expected state sequence and completed successfully.

Note: Express Workflows do not support get_execution_history(). These tests use:
  - describe_execution()  for pass/fail status
  - filter_log_events()   for state-entry verification (requires level=ALL on the SFN)
"""
import json
import time

import pytest

CW_LOG_GROUP   = "/aws/states/ReadmeGeneratorPipeline"
EXPECTED_STATES = [
    "ScanRepo",
    "AnalyzeInParallel",
    "AssembleCompilerInput",
    "CompileReadme",
    "UploadReadme",
]


def test_last_execution_succeeded(last_execution_arn, sfn_client):
    """The most recent pipeline execution completed successfully."""
    desc   = sfn_client.describe_execution(executionArn=last_execution_arn)
    status = desc["status"]
    assert status == "SUCCEEDED", (
        f"Execution ended with '{status}'.\n"
        f"Execution ARN: {last_execution_arn}\n"
        f"Check logs: aws logs tail {CW_LOG_GROUP} --since 1h --region us-west-2"
    )


def test_last_execution_has_output(last_execution_arn, sfn_client):
    """The pipeline produced an output payload (README was compiled)."""
    desc = sfn_client.describe_execution(executionArn=last_execution_arn)
    assert desc.get("output"), (
        "Execution SUCCEEDED but produced no output payload — "
        "UploadReadme state may not have run."
    )


def test_all_states_entered(last_execution_arn, logs_client):
    """
    All expected states were entered, verified via CloudWatch Logs.
    Requires the SFN state machine logging level=ALL (set in infra/main.tf).
    Skipped automatically if CW Logs returns no results (e.g. logs delayed).
    """
    # Look back 1 hour for events from this execution.
    start_ms = int((time.time() - 3600) * 1000)

    paginator    = logs_client.get_paginator("filter_log_events")
    entered      = set()
    found_events = False

    for page in paginator.paginate(
        logGroupName=CW_LOG_GROUP,
        startTime=start_ms,
        filterPattern=f'"TaskStateEntered" "{last_execution_arn}"',
        PaginationConfig={"MaxItems": 200},
    ):
        for event in page.get("events", []):
            found_events = True
            try:
                msg = json.loads(event["message"])
                if msg.get("type") == "TaskStateEntered":
                    name = msg.get("details", {}).get("name")
                    if name:
                        entered.add(name)
            except (json.JSONDecodeError, KeyError):
                pass

    if not found_events:
        pytest.skip(
            "No TaskStateEntered events found in CloudWatch Logs — "
            "ensure SFN logging level=ALL is applied (terraform apply)."
        )

    for state in EXPECTED_STATES:
        assert state in entered, (
            f"State '{state}' was never entered.\n"
            f"States seen: {sorted(entered)}"
        )


def test_no_failed_states(last_execution_arn, logs_client):
    """No state machine states transitioned to a Failed terminal state."""
    start_ms = int((time.time() - 3600) * 1000)

    paginator   = logs_client.get_paginator("filter_log_events")
    failed_msgs = []

    for page in paginator.paginate(
        logGroupName=CW_LOG_GROUP,
        startTime=start_ms,
        filterPattern=f'"Failed" "{last_execution_arn}"',
        PaginationConfig={"MaxItems": 50},
    ):
        for event in page.get("events", []):
            try:
                msg = json.loads(event["message"])
                if "Failed" in msg.get("type", ""):
                    failed_msgs.append(msg)
            except (json.JSONDecodeError, KeyError):
                pass

    assert not failed_msgs, (
        f"{len(failed_msgs)} failed state(s) found:\n"
        + json.dumps(failed_msgs, indent=2, default=str)
    )
