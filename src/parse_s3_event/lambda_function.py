import json
import os
import urllib.parse

import boto3

sfn = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]

AGENTS = {
    "repo_scanner": {
        "id": os.environ["REPO_SCANNER_AGENT_ID"],
        "alias": os.environ["REPO_SCANNER_AGENT_ALIAS_ID"],
    },
    "project_summarizer": {
        "id": os.environ["PROJECT_SUMMARIZER_AGENT_ID"],
        "alias": os.environ["PROJECT_SUMMARIZER_AGENT_ALIAS_ID"],
    },
    "installation_guide": {
        "id": os.environ["INSTALLATION_GUIDE_AGENT_ID"],
        "alias": os.environ["INSTALLATION_GUIDE_AGENT_ALIAS_ID"],
    },
    "usage_examples": {
        "id": os.environ["USAGE_EXAMPLES_AGENT_ID"],
        "alias": os.environ["USAGE_EXAMPLES_AGENT_ALIAS_ID"],
    },
    "final_compiler": {
        "id": os.environ["FINAL_COMPILER_AGENT_ID"],
        "alias": os.environ["FINAL_COMPILER_AGENT_ALIAS_ID"],
    },
}


def handler(event, context):
    key = urllib.parse.unquote_plus(event["Records"][0]["s3"]["object"]["key"])
    filename = key.replace("inputs/", "")

    # Reverse the encoding applied by generate.sh:
    #   https---github.com-owner-repo  ->  https://github.com/owner/repo
    repo_url = filename.replace("---", "://", 1)
    parts = repo_url.split("://", 1)
    if len(parts) == 2:
        domain_and_path = parts[1].replace("-", "/", 2)
        repo_url = parts[0] + "://" + domain_and_path

    repo_name = repo_url.rstrip("/").split("/")[-1].replace(".git", "")

    sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=f"{repo_name}-{context.aws_request_id}",
        input=json.dumps(
            {
                "repo_url": repo_url,
                "repo_name": repo_name,
                "output_key": f"outputs/{repo_name}/README.md",
                "output_bucket": OUTPUT_BUCKET,
                "session_id": context.aws_request_id,
                "agents": AGENTS,
            }
        ),
    )
    return {"statusCode": 200}
