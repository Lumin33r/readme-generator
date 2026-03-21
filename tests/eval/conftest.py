"""
pytest fixtures for README Generator eval tests.

Environment variables (set by CI workflows or locally via terraform output):
    README_BUCKET_NAME   — S3 bucket name
    STATE_MACHINE_ARN    — Step Functions state machine ARN
"""
import contextlib
import json
import os
import subprocess
import time

import boto3
import pytest

REGION = "us-west-2"
POLL_INTERVAL = 10
TIMEOUT = 300

# Map from golden slug → full GitHub URL
GITHUB_REPO_MAP = {
    "modelcontextprotocol": "https://github.com/modelcontextprotocol/modelcontextprotocol",
    "fastapi":               "https://github.com/tiangolo/fastapi",
    "hello-world":           "https://github.com/octocat/Hello-World",
}


# ---------------------------------------------------------------------------
# Infrastructure fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def s3_client():
    return boto3.client("s3", region_name=REGION)


@pytest.fixture(scope="session")
def sfn_client():
    return boto3.client("stepfunctions", region_name=REGION)


@pytest.fixture(scope="session")
def logs_client():
    return boto3.client("logs", region_name=REGION)


def _tf_output(name: str) -> str:
    result = subprocess.run(
        ["terraform", "output", "-raw", name],
        capture_output=True, text=True, cwd="infra",
    )
    return result.stdout.strip()


@pytest.fixture(scope="session")
def bucket_name():
    return os.environ.get("README_BUCKET_NAME") or _tf_output("readme_bucket_name")


@pytest.fixture(scope="session")
def state_machine_arn():
    return os.environ.get("STATE_MACHINE_ARN") or _tf_output("state_machine_arn")


# ---------------------------------------------------------------------------
# Pipeline trigger fixture
# ---------------------------------------------------------------------------

def _encode_repo_url(repo_url: str) -> str:
    """Mirror generate.sh encoding: https://github.com/owner/repo → https---github.com-owner-repo"""
    return repo_url.replace("://", "---").replace("/", "-")


def _poll_for_output(s3_client, bucket: str, key: str, timeout: int = TIMEOUT) -> str:
    elapsed = 0
    while elapsed < timeout:
        try:
            obj = s3_client.get_object(Bucket=bucket, Key=key)
            return obj["Body"].read().decode("utf-8")
        except s3_client.exceptions.NoSuchKey:
            pass
        except Exception as exc:
            if "NoSuchKey" in str(exc):
                pass
            else:
                raise
        time.sleep(POLL_INTERVAL)
        elapsed += POLL_INTERVAL
    raise TimeoutError(f"README not produced within {timeout}s (key: {key})")


@pytest.fixture()
def trigger_pipeline(s3_client, bucket_name):
    """
    Returns a callable that produces a README for the given repo slug.

    In CI (env var CI=true), reads the output already placed by generate.sh in
    eval.yml rather than re-triggering the pipeline.  Falls back to triggering
    if the output key is not yet present.
    """
    triggered_keys: list[str] = []

    def _get_or_trigger(repo_slug: str) -> str:
        output_key = f"outputs/{repo_slug}/README.md"

        if os.environ.get("CI"):
            with contextlib.suppress(Exception):
                obj = s3_client.get_object(Bucket=bucket_name, Key=output_key)
                return obj["Body"].read().decode("utf-8")

        # Delete stale output so we get a fresh run.
        with contextlib.suppress(Exception):
            s3_client.delete_object(Bucket=bucket_name, Key=output_key)

        repo_url = GITHUB_REPO_MAP[repo_slug]
        encoded  = _encode_repo_url(repo_url)
        s3_client.put_object(Bucket=bucket_name, Key=f"inputs/{encoded}", Body=b"")
        triggered_keys.append(output_key)
        return _poll_for_output(s3_client, bucket_name, output_key)

    yield _get_or_trigger

    # Cleanup outputs produced by standalone test runs.
    for key in triggered_keys:
        with contextlib.suppress(Exception):
            s3_client.delete_object(Bucket=bucket_name, Key=key)


# ---------------------------------------------------------------------------
# SFN execution fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def last_execution_arn(sfn_client, state_machine_arn):
    """
    Returns the ARN of the most recently started SFN execution after waiting
    for it to leave the RUNNING state (up to 5 minutes).
    """
    resp = sfn_client.list_executions(stateMachineArn=state_machine_arn, maxResults=1)
    assert resp["executions"], "No SFN executions found — has the pipeline been triggered?"
    arn = resp["executions"][0]["executionArn"]

    # Wait for the execution to finish (Express Workflows may still be running).
    deadline = time.time() + 300
    while time.time() < deadline:
        desc = sfn_client.describe_execution(executionArn=arn)
        if desc["status"] != "RUNNING":
            break
        time.sleep(5)

    return arn
