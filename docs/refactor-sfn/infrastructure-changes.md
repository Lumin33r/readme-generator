# Infrastructure Changes — Step Functions Refactor

This document lists every Terraform resource that must be added, modified, or removed.
All changes are relative to the current `infra/main.tf`.

---

## Resources to Remove

| Resource                                                         | Reason                                                       |
| ---------------------------------------------------------------- | ------------------------------------------------------------ |
| `aws_lambda_function.orchestrator_lambda`                        | Replaced by SFN state machine + ParseS3Event Lambda          |
| `data.archive_file.orchestrator_zip`                             | Source directory `src/orchestrator/` no longer deployed      |
| `module.orchestrator_execution_role`                             | Role replaced by two new dedicated roles                     |
| `aws_iam_policy.orchestrator_permissions`                        | Replaced by `sfn_execution_policy` + `parse_s3_event_policy` |
| `aws_iam_role_policy_attachment.orchestrator_permissions_attach` | Goes with the policy above                                   |
| `aws_lambda_permission.allow_s3_to_invoke_orchestrator`          | S3 now invokes ParseS3Event, not Orchestrator                |

---

## Resources to Add

### 1. `AgentInvoker` Lambda

```hcl
data "archive_file" "agent_invoker_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/agent_invoker"
  output_path = "${path.root}/../dist/agent_invoker.zip"
}

resource "aws_iam_role" "agent_invoker_role" {
  name = "ReadmeGeneratorAgentInvokerRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "agent_invoker_basic" {
  role       = aws_iam_role.agent_invoker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "agent_invoker_bedrock" {
  name = "AgentInvokerBedrockPolicy"
  role = aws_iam_role.agent_invoker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["bedrock:InvokeAgent", "bedrock-agent-runtime:InvokeAgent"]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "agent_invoker" {
  function_name    = "ReadmeGeneratorAgentInvoker"
  role             = aws_iam_role.agent_invoker_role.arn
  filename         = data.archive_file.agent_invoker_zip.output_path
  source_code_hash = data.archive_file.agent_invoker_zip.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 90  # must be >= longest agent call (ScanRepo timeout)
}
```

---

### 2. `ParseS3Event` Lambda

```hcl
data "archive_file" "parse_s3_event_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/parse_s3_event"
  output_path = "${path.root}/../dist/parse_s3_event.zip"
}

resource "aws_iam_role" "parse_s3_event_role" {
  name = "ReadmeGeneratorParseS3EventRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "parse_s3_event_basic" {
  role       = aws_iam_role.parse_s3_event_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parse_s3_event_sfn" {
  name = "ParseS3EventStartExecutionPolicy"
  role = aws_iam_role.parse_s3_event_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.readme_generator.arn
    }]
  })
}

resource "aws_lambda_function" "parse_s3_event" {
  function_name    = "ReadmeGeneratorParseS3Event"
  role             = aws_iam_role.parse_s3_event_role.arn
  filename         = data.archive_file.parse_s3_event_zip.output_path
  source_code_hash = data.archive_file.parse_s3_event_zip.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 10

  environment {
    variables = {
      STATE_MACHINE_ARN                = aws_sfn_state_machine.readme_generator.arn
      OUTPUT_BUCKET                    = module.s3_bucket.bucket_id
      REPO_SCANNER_AGENT_ID            = module.repo_scanner_agent.agent_id
      REPO_SCANNER_AGENT_ALIAS_ID      = "TSTALIASID"
      PROJECT_SUMMARIZER_AGENT_ID      = module.project_summarizer_agent.agent_id
      PROJECT_SUMMARIZER_AGENT_ALIAS_ID = "TSTALIASID"
      INSTALLATION_GUIDE_AGENT_ID      = module.installation_guide_agent.agent_id
      INSTALLATION_GUIDE_AGENT_ALIAS_ID = "TSTALIASID"
      USAGE_EXAMPLES_AGENT_ID          = module.usage_examples_agent.agent_id
      USAGE_EXAMPLES_AGENT_ALIAS_ID    = "TSTALIASID"
      FINAL_COMPILER_AGENT_ID          = module.final_compiler_agent.agent_id
      FINAL_COMPILER_AGENT_ALIAS_ID    = "TSTALIASID"
    }
  }
}
```

---

### 3. Step Functions Execution Role

SFN needs permission to invoke the `AgentInvoker` Lambda and write to S3 (for the
`UploadReadme` direct SDK step) and to log to CloudWatch.

```hcl
resource "aws_iam_role" "sfn_execution_role" {
  name = "ReadmeGeneratorSFNExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_execution_policy" {
  name = "ReadmeGeneratorSFNPolicy"
  role = aws_iam_role.sfn_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeAgentInvoker"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.agent_invoker.arn
      },
      {
        Sid      = "WriteOutputToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.s3_bucket.bucket_arn}/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}
```

---

### 4. Step Functions State Machine

```hcl
resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/ReadmeGeneratorPipeline"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "readme_generator" {
  name     = "ReadmeGeneratorPipeline"
  role_arn = aws_iam_role.sfn_execution_role.arn
  type     = "EXPRESS"  # sub-5-minute, async-safe, lower cost than STANDARD

  definition = templatefile("${path.root}/../src/sfn/state_machine.asl.json", {
    AgentInvokerFunctionArn = aws_lambda_function.agent_invoker.arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ERROR"  # set to ALL during development
  }
}
```

---

### 5. Updated S3 Notification and Lambda Permission

Replace the existing `allow_s3_to_invoke_orchestrator` permission and
`bucket_notification` resource to point at `ParseS3Event` instead of the Orchestrator.

```hcl
# Remove old: aws_lambda_permission.allow_s3_to_invoke_orchestrator
# Add new:
resource "aws_lambda_permission" "allow_s3_to_invoke_parse" {
  statement_id  = "AllowS3ToInvokeParseS3EventLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parse_s3_event.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.s3_bucket.bucket_arn
}

# Update existing aws_s3_bucket_notification.bucket_notification:
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = module.s3_bucket.bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.parse_s3_event.arn  # changed
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/"
  }

  depends_on = [aws_lambda_permission.allow_s3_to_invoke_parse]  # updated
}
```

---

## Resource Change Summary

| Action    | Count | Resource types                                                                                                                                            |
| --------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Add       | 13    | 2× Lambda, 2× IAM role, 3× IAM policy/attachment, 1× SFN state machine, 1× CW log group, 1× Lambda permission, 2× archive_file, 1× S3 notification update |
| Remove    | 6     | 1× Lambda, 1× archive_file, 1× IAM module call, 1× IAM policy, 1× policy attachment, 1× Lambda permission                                                 |
| Modify    | 1     | `aws_s3_bucket_notification` (Lambda ARN pointer only)                                                                                                    |
| Unchanged | Many  | All 5 Bedrock agents, RepoScannerTool Lambda, S3 bucket, DynamoDB, GitHub Actions role                                                                    |

---

## New Project Structure

```
readme-generator/
├── src/
│   ├── repo_scanner/
│   │   └── lambda_function.py        # Unchanged
│   ├── parse_s3_event/               # NEW
│   │   └── lambda_function.py
│   ├── agent_invoker/                # NEW
│   │   └── lambda_function.py
│   └── sfn/                          # NEW
│       └── state_machine.asl.json
└── infra/
    └── main.tf                       # Updated as above
```

The `src/orchestrator/` directory and its Lambda function can be deleted after
successful deployment and smoke test.
