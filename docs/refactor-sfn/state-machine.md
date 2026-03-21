# State Machine Definition — ReadmeGeneratorPipeline

## Overview

The state machine is an **Express Workflow** (synchronous, sub-5-minute, lower cost
than Standard Workflows). It accepts structured input from `ParseS3Event` Lambda and
owns the entire agent invocation pipeline.

---

## Input Contract

`ParseS3Event` must call `sfn:StartExecution` with the following JSON:

```json
{
  "repo_url": "https://github.com/owner/repo",
  "repo_name": "repo",
  "output_key": "outputs/repo/README.md",
  "output_bucket": "readme-generator-output-bucket-mg481ly5",
  "session_id": "aws-request-id-uuid",
  "agents": {
    "repo_scanner": { "id": "NE0CSDQPDP", "alias": "TSTALIASID" },
    "project_summarizer": { "id": "PHM7GVBXKT", "alias": "TSTALIASID" },
    "installation_guide": { "id": "VXXWEHVIBC", "alias": "TSTALIASID" },
    "usage_examples": { "id": "2H19BVYH2V", "alias": "TSTALIASID" },
    "final_compiler": { "id": "ODTFJA4DKP", "alias": "TSTALIASID" }
  }
}
```

Agent IDs are injected by `ParseS3Event` from its own environment variables (set by
Terraform). This keeps the state machine definition itself agent-ID-agnostic — you can
swap agents without redeploying the state machine.

---

## State Machine Definition (ASL)

Save as `src/sfn/state_machine.asl.json`. The `${AgentInvokerFunctionArn}` token is
replaced at deploy time by Terraform's `templatefile()` or `jsonencode()`.

```json
{
  "Comment": "README Generator — parallel Bedrock agent pipeline",
  "StartAt": "ScanRepo",
  "States": {
    "ScanRepo": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${AgentInvokerFunctionArn}",
        "Payload": {
          "agent_id.$": "$.agents.repo_scanner.id",
          "alias_id.$": "$.agents.repo_scanner.alias",
          "session_id.$": "$.session_id",
          "input_text.$": "$.repo_url"
        }
      },
      "ResultSelector": {
        "file_list.$": "$.Payload.result"
      },
      "ResultPath": "$.scan_result",
      "TimeoutSeconds": 90,
      "Retry": [
        {
          "ErrorEquals": [
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.TooManyRequestsException",
            "States.TaskFailed"
          ],
          "IntervalSeconds": 5,
          "MaxAttempts": 2,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "ScanFailed",
          "ResultPath": "$.error"
        }
      ],
      "Next": "AnalyzeInParallel"
    },

    "AnalyzeInParallel": {
      "Type": "Parallel",
      "Branches": [
        {
          "StartAt": "SummarizeProject",
          "States": {
            "SummarizeProject": {
              "Type": "Task",
              "Resource": "arn:aws:states:::lambda:invoke",
              "Parameters": {
                "FunctionName": "${AgentInvokerFunctionArn}",
                "Payload": {
                  "agent_id.$": "$.agents.project_summarizer.id",
                  "alias_id.$": "$.agents.project_summarizer.alias",
                  "session_id.$": "$.session_id",
                  "input_text.$": "$.scan_result.file_list"
                }
              },
              "ResultSelector": {
                "project_summary.$": "$.Payload.result"
              },
              "TimeoutSeconds": 60,
              "Retry": [
                {
                  "ErrorEquals": [
                    "States.TaskFailed",
                    "Lambda.ServiceException"
                  ],
                  "IntervalSeconds": 5,
                  "MaxAttempts": 2,
                  "BackoffRate": 2
                }
              ],
              "End": true
            }
          }
        },

        {
          "StartAt": "WriteInstallationGuide",
          "States": {
            "WriteInstallationGuide": {
              "Type": "Task",
              "Resource": "arn:aws:states:::lambda:invoke",
              "Parameters": {
                "FunctionName": "${AgentInvokerFunctionArn}",
                "Payload": {
                  "agent_id.$": "$.agents.installation_guide.id",
                  "alias_id.$": "$.agents.installation_guide.alias",
                  "session_id.$": "$.session_id",
                  "input_text.$": "$.scan_result.file_list"
                }
              },
              "ResultSelector": {
                "installation_guide.$": "$.Payload.result"
              },
              "TimeoutSeconds": 60,
              "Retry": [
                {
                  "ErrorEquals": [
                    "States.TaskFailed",
                    "Lambda.ServiceException"
                  ],
                  "IntervalSeconds": 5,
                  "MaxAttempts": 2,
                  "BackoffRate": 2
                }
              ],
              "End": true
            }
          }
        },

        {
          "StartAt": "WriteUsageExamples",
          "States": {
            "WriteUsageExamples": {
              "Type": "Task",
              "Resource": "arn:aws:states:::lambda:invoke",
              "Parameters": {
                "FunctionName": "${AgentInvokerFunctionArn}",
                "Payload": {
                  "agent_id.$": "$.agents.usage_examples.id",
                  "alias_id.$": "$.agents.usage_examples.alias",
                  "session_id.$": "$.session_id",
                  "input_text.$": "$.scan_result.file_list"
                }
              },
              "ResultSelector": {
                "usage_examples.$": "$.Payload.result"
              },
              "TimeoutSeconds": 60,
              "Retry": [
                {
                  "ErrorEquals": [
                    "States.TaskFailed",
                    "Lambda.ServiceException"
                  ],
                  "IntervalSeconds": 5,
                  "MaxAttempts": 2,
                  "BackoffRate": 2
                }
              ],
              "End": true
            }
          }
        }
      ],
      "ResultPath": "$.parallel_results",
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "AnalysisFailed",
          "ResultPath": "$.error"
        }
      ],
      "Next": "AssembleCompilerInput"
    },

    "AssembleCompilerInput": {
      "Type": "Pass",
      "Comment": "Reshapes parallel branch array into a named object for FinalCompiler. No Lambda, no cost.",
      "Parameters": {
        "repository_name.$": "$.repo_name",
        "project_summary.$": "$.parallel_results[0].project_summary",
        "installation_guide.$": "$.parallel_results[1].installation_guide",
        "usage_examples.$": "$.parallel_results[2].usage_examples"
      },
      "ResultPath": "$.assembled.compiler_input",
      "Next": "CompileReadme"
    },

    "CompileReadme": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${AgentInvokerFunctionArn}",
        "Payload": {
          "agent_id.$": "$.agents.final_compiler.id",
          "alias_id.$": "$.agents.final_compiler.alias",
          "session_id.$": "$.session_id",
          "input_text.$": "States.JsonToString($.assembled.compiler_input)"
        }
      },
      "ResultSelector": {
        "readme_content.$": "$.Payload.result"
      },
      "ResultPath": "$.compile_result",
      "TimeoutSeconds": 60,
      "Retry": [
        {
          "ErrorEquals": ["States.TaskFailed", "Lambda.ServiceException"],
          "IntervalSeconds": 5,
          "MaxAttempts": 2,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "CompileFailed",
          "ResultPath": "$.error"
        }
      ],
      "Next": "UploadReadme"
    },

    "UploadReadme": {
      "Type": "Task",
      "Resource": "arn:aws:states:::aws-sdk:s3:putObject",
      "Parameters": {
        "Bucket.$": "$.output_bucket",
        "Key.$": "$.output_key",
        "Body.$": "$.compile_result.readme_content",
        "ContentType": "text/markdown"
      },
      "TimeoutSeconds": 10,
      "Retry": [
        {
          "ErrorEquals": ["S3.S3Exception"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "End": true
    },

    "ScanFailed": {
      "Type": "Fail",
      "Error": "ScanRepoFailed",
      "Cause": "RepoScannerAgent returned an error after retries. Check /aws/lambda/AgentInvoker and /aws/lambda/RepoScannerTool logs."
    },

    "AnalysisFailed": {
      "Type": "Fail",
      "Error": "AnalysisParallelFailed",
      "Cause": "One or more parallel analysis agents failed. Check /aws/lambda/AgentInvoker logs."
    },

    "CompileFailed": {
      "Type": "Fail",
      "Error": "FinalCompilerFailed",
      "Cause": "FinalCompilerAgent failed to generate README. Check /aws/lambda/AgentInvoker logs."
    }
  }
}
```

---

## Execution Context at Each State

| After State             | New field added to `$`                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------ |
| Input                   | `$.repo_url`, `$.repo_name`, `$.output_key`, `$.output_bucket`, `$.session_id`, `$.agents` |
| `ScanRepo`              | `$.scan_result.file_list`                                                                  |
| `AnalyzeInParallel`     | `$.parallel_results[0].project_summary`, `[1].installation_guide`, `[2].usage_examples`    |
| `AssembleCompilerInput` | `$.assembled.compiler_input` (repository_name + all three sections)                        |
| `CompileReadme`         | `$.compile_result.readme_content`                                                          |
| `UploadReadme`          | S3 PutObject response (not used, state ends)                                               |

---

## Lambda Source Code

### `src/agent_invoker/lambda_function.py`

This is the only Lambda the state machine invokes. It has no business logic — it is
purely a streaming adapter between SFN and the Bedrock Agent Runtime API.

```python
# src/agent_invoker/lambda_function.py
import json
import boto3

client = boto3.client('bedrock-agent-runtime')

def handler(event, context):
    response = client.invoke_agent(
        agentId=event['agent_id'],
        agentAliasId=event['alias_id'],
        sessionId=event['session_id'],
        inputText=event['input_text']
    )

    result = ""
    for chunk_event in response['completion']:
        if 'chunk' in chunk_event:
            result += chunk_event['chunk']['bytes'].decode()

    return {"result": result}
```

### `src/parse_s3_event/lambda_function.py`

Bridges the S3 ObjectCreated notification to a Step Functions execution start. All URL
decoding logic from the original Orchestrator moves here. No agent calls take place.

```python
# src/parse_s3_event/lambda_function.py
import json
import boto3
import os
import urllib.parse

sfn = boto3.client('stepfunctions')

STATE_MACHINE_ARN = os.environ['STATE_MACHINE_ARN']
OUTPUT_BUCKET     = os.environ['OUTPUT_BUCKET']

AGENTS = {
    "repo_scanner":       {"id": os.environ['REPO_SCANNER_AGENT_ID'],       "alias": os.environ['REPO_SCANNER_AGENT_ALIAS_ID']},
    "project_summarizer": {"id": os.environ['PROJECT_SUMMARIZER_AGENT_ID'], "alias": os.environ['PROJECT_SUMMARIZER_AGENT_ALIAS_ID']},
    "installation_guide": {"id": os.environ['INSTALLATION_GUIDE_AGENT_ID'], "alias": os.environ['INSTALLATION_GUIDE_AGENT_ALIAS_ID']},
    "usage_examples":     {"id": os.environ['USAGE_EXAMPLES_AGENT_ID'],     "alias": os.environ['USAGE_EXAMPLES_AGENT_ALIAS_ID']},
    "final_compiler":     {"id": os.environ['FINAL_COMPILER_AGENT_ID'],     "alias": os.environ['FINAL_COMPILER_AGENT_ALIAS_ID']},
}

def handler(event, context):
    key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])

    filename = key.replace('inputs/', '')
    repo_url = filename.replace('---', '://', 1)
    parts = repo_url.split('://', 1)
    if len(parts) == 2:
        domain_and_path = parts[1].replace('-', '/', 2)
        repo_url = parts[0] + '://' + domain_and_path

    repo_name = repo_url.split('/')[-1].replace('.git', '')

    sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=f"{repo_name}-{context.aws_request_id}",
        input=json.dumps({
            "repo_url":      repo_url,
            "repo_name":     repo_name,
            "output_key":    f"outputs/{repo_name}/README.md",
            "output_bucket": OUTPUT_BUCKET,
            "session_id":    context.aws_request_id,
            "agents":        AGENTS,
        })
    )

    return {"statusCode": 200}
```

---

## Payload Overflow Pattern

If execution state exceeds the **256 KB SFN context limit** (most likely from a large
file list on a monorepo), use S3 as an intermediary:

1. After `ScanRepo` completes, add an `StoreFileList` Task state that writes
   `$.scan_result.file_list` to S3 at a temp key (e.g. `tmp/{session_id}/file_list.txt`).
2. Replace `input_text.$: "$.scan_result.file_list"` in all three parallel branches with
   `input_text.$: "$.scan_result.s3_key"` (the S3 key).
3. Update `AgentInvoker` to detect an `s3_key` parameter, read the content from S3, and
   pass the content as `inputText` to `invoke_agent`.

This pattern adds one S3 read/write per execution but removes the 256 KB ceiling
entirely. Implement it only when a real size error is observed — don't pre-optimize.

---

## Timeout Budget

| State                   | Timeout | Runs                         | Worst-case contribution |
| ----------------------- | ------- | ---------------------------- | ----------------------- |
| `ScanRepo`              | 90s     | 1×                           | 90s                     |
| `AnalyzeInParallel`     | 60s     | 1× (3 branches concurrently) | 60s                     |
| `AssembleCompilerInput` | —       | Pass                         | ~0s                     |
| `CompileReadme`         | 60s     | 1×                           | 60s                     |
| `UploadReadme`          | 10s     | 1×                           | 10s                     |
| **Total worst case**    |         |                              | **220s**                |

Express Workflows support up to 5 minutes (300s). This fits with 80s of headroom.
