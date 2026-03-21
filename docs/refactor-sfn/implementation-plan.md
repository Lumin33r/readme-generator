# Implementation Plan — Step Functions Refactor

Each step produces a working, deployable increment. Do not skip steps — each one
validates the foundation for the next.

---

## Step 1 — Write and Deploy `AgentInvoker` Lambda

**Goal:** A working streaming adapter Lambda before the state machine references it.

- [ ] Create `src/agent_invoker/lambda_function.py` (see [state-machine.md](./state-machine.md#lambdasource-code))
- [ ] Add `archive_file.agent_invoker_zip`, `aws_iam_role.agent_invoker_role`,
      `aws_iam_role_policy_attachment.agent_invoker_basic`,
      `aws_iam_role_policy.agent_invoker_bedrock`, and
      `aws_lambda_function.agent_invoker` to `infra/main.tf`
- [ ] `terraform apply`
- [ ] Smoke-test by invoking directly:
  ```bash
  aws lambda invoke \
    --function-name ReadmeGeneratorAgentInvoker \
    --cli-binary-format raw-in-base64-out \
    --payload '{"agent_id":"NE0CSDQPDP","alias_id":"TSTALIASID","session_id":"test-1","input_text":"https://github.com/Lumin33r/fastapi-probe-demo"}' \
    --region us-west-2 /tmp/agent_invoker_test.json \
    && cat /tmp/agent_invoker_test.json
  ```
- [ ] Confirm response contains `{"result": "... file list ..."}` (not an error)

**Resources created:** 1 Lambda, 1 IAM role, 2 IAM policies

---

## Step 2 — Write and Deploy the State Machine

**Goal:** A working Express Workflow that can be triggered manually.

- [ ] Create `src/sfn/state_machine.asl.json` (see [state-machine.md](./state-machine.md#state-machine-definition-asl))
      Note: keep `${AgentInvokerFunctionArn}` as the token literal — Terraform's
      `templatefile()` replaces it at apply time.
- [ ] Add `aws_cloudwatch_log_group.sfn_logs`, `aws_iam_role.sfn_execution_role`,
      `aws_iam_role_policy.sfn_execution_policy`, and
      `aws_sfn_state_machine.readme_generator` to `infra/main.tf`
- [ ] `terraform apply`
- [ ] Smoke-test by triggering the state machine manually from the CLI:

  ```bash
  # Get the actual agent IDs from env
  SCANNER_ID=$(aws lambda get-function-configuration \
    --function-name ReadmeGeneratorParseS3Event \
    --query 'Environment.Variables.REPO_SCANNER_AGENT_ID' \
    --output text --region us-west-2 2>/dev/null || echo "NE0CSDQPDP")

  SFN_ARN=$(aws stepfunctions list-state-machines \
    --region us-west-2 \
    --query "stateMachines[?name=='ReadmeGeneratorPipeline'].stateMachineArn" \
    --output text)

  aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --region us-west-2 \
    --input '{
      "repo_url": "https://github.com/Lumin33r/fastapi-probe-demo",
      "repo_name": "fastapi-probe-demo",
      "output_key": "outputs/fastapi-probe-demo/README.md",
      "output_bucket": "readme-generator-output-bucket-mg481ly5",
      "session_id": "manual-test-001",
      "agents": {
        "repo_scanner":       {"id": "NE0CSDQPDP", "alias": "TSTALIASID"},
        "project_summarizer": {"id": "PHM7GVBXKT", "alias": "TSTALIASID"},
        "installation_guide": {"id": "VXXWEHVIBC", "alias": "TSTALIASID"},
        "usage_examples":     {"id": "2H19BVYH2V", "alias": "TSTALIASID"},
        "final_compiler":     {"id": "ODTFJA4DKP", "alias": "TSTALIASID"}
      }
    }'
  ```

- [ ] Watch execution in the Step Functions console (AWS Console → Step Functions →
      ReadmeGeneratorPipeline → Executions)
- [ ] Confirm README.md written to `s3://readme-generator-output-bucket-mg481ly5/outputs/fastapi-probe-demo/README.md`

**Resources created:** 1 SFN state machine, 1 IAM role, 1 IAM policy, 1 CW log group

---

## Step 3 — Write and Deploy `ParseS3Event` Lambda

**Goal:** Restore the S3-triggered flow using the new bridge Lambda.

- [ ] Create `src/parse_s3_event/lambda_function.py` (see [state-machine.md](./state-machine.md#lambdasource-code))
- [ ] Add `archive_file.parse_s3_event_zip`, `aws_iam_role.parse_s3_event_role`,
      `aws_iam_role_policy_attachment.parse_s3_event_basic`,
      `aws_iam_role_policy.parse_s3_event_sfn`, and
      `aws_lambda_function.parse_s3_event` to `infra/main.tf`
- [ ] `terraform apply`
- [ ] Confirm Lambda deployed with correct `STATE_MACHINE_ARN` env var:
  ```bash
  aws lambda get-function-configuration \
    --function-name ReadmeGeneratorParseS3Event \
    --region us-west-2 \
    --query 'Environment.Variables.STATE_MACHINE_ARN'
  ```

**Resources created:** 1 Lambda, 1 IAM role, 2 IAM policies

---

## Step 4 — Swap the S3 Trigger

**Goal:** S3 upload fires `ParseS3Event` instead of the old Orchestrator Lambda.

- [ ] In `infra/main.tf`, add `aws_lambda_permission.allow_s3_to_invoke_parse`
- [ ] Update `aws_s3_bucket_notification.bucket_notification` to use
      `aws_lambda_function.parse_s3_event.arn` (and update `depends_on`)
- [ ] Remove `aws_lambda_permission.allow_s3_to_invoke_orchestrator`
- [ ] `terraform apply`
- [ ] End-to-end test using `generate.sh`:
  ```bash
  ./generate.sh https://github.com/Lumin33r/fastapi-probe-demo
  ```
- [ ] Confirm output arrives within ~120s (should be faster than the old 150s)
- [ ] Verify new execution visible in Step Functions console

---

## Step 5 — Remove the Old Orchestrator

**Goal:** Clean up the replaced resources. Only do this after Step 4 passes.

- [ ] Remove `aws_lambda_function.orchestrator_lambda` from `infra/main.tf`
- [ ] Remove `data.archive_file.orchestrator_zip`
- [ ] Remove `module.orchestrator_execution_role`
- [ ] Remove `aws_iam_policy.orchestrator_permissions`
- [ ] Remove `aws_iam_role_policy_attachment.orchestrator_permissions_attach`
- [ ] `terraform apply` — confirm 5 resources destroyed, no errors
- [ ] Delete `src/orchestrator/` directory (optional, keep for reference until confident)
- [ ] Run `generate.sh` one more time to confirm clean end-to-end

---

## Step 6 — Observability Tuning (Optional)

- [ ] Change `aws_sfn_state_machine.readme_generator` logging level from `ERROR` to `ALL`
      during development for full input/output visibility per state
- [ ] Add a CloudWatch Dashboard with:
  - SFN `ExecutionsFailed` metric
  - SFN `ExecutionTime` metric (p50, p95)
  - Lambda `Duration` for `AgentInvoker` (p95)
- [ ] Set CW Alarm on `ExecutionsFailed > 0` for the state machine

---

## Rollback Plan

If any step fails, the old Orchestrator Lambda still exists until Step 5. To roll back:

1. Revert `aws_s3_bucket_notification.bucket_notification` to point at
   `aws_lambda_function.orchestrator_lambda.arn`
2. Restore `aws_lambda_permission.allow_s3_to_invoke_orchestrator`
3. `terraform apply`

The state machine and new Lambdas can remain — they don't affect the S3→Orchestrator
path until Step 4 is applied.

---

## Validation Checklist

| Test                              | Command / Location                                  | Expected result                                                |
| --------------------------------- | --------------------------------------------------- | -------------------------------------------------------------- |
| AgentInvoker Lambda direct invoke | `aws lambda invoke ... ReadmeGeneratorAgentInvoker` | `{"result": "file list content.."}`                            |
| State machine manual execution    | SFN console or `aws stepfunctions start-execution`  | Execution succeeds, README in S3                               |
| S3-triggered end-to-end           | `./generate.sh <url>`                               | README downloaded, exit 0                                      |
| Parallel speedup                  | SFN console → Execution detail → timeline           | 3 branches running simultaneously                              |
| CloudWatch logs                   | `/aws/lambda/ReadmeGeneratorAgentInvoker`           | 5 invocations per pipeline run                                 |
| Error path                        | Trigger with invalid repo URL                       | `ScanFailed` state reached, Fail state recorded in SFN console |
