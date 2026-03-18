# Infrastructure — AI README.md Generator

## Terraform Module Architecture

The infrastructure is organized as three reusable Terraform modules called from a single root `main.tf`.

```
modules/
├── s3/              # Generic S3 bucket creation
├── iam/             # Generic IAM role with policy attachments
└── bedrock_agent/   # Generic Bedrock Agent creation
```

### Module: `modules/s3`

| File           | Purpose                          |
| -------------- | -------------------------------- |
| `variables.tf` | `bucket_name` (string, required) |
| `main.tf`      | `aws_s3_bucket.this`             |
| `outputs.tf`   | `bucket_id`, `bucket_arn`        |

**Usage in root:** Called once for the output bucket.

```hcl
module "s3_bucket" {
  source      = "./modules/s3"
  bucket_name = "readme-generator-output-bucket-${random_string.suffix.result}"
}
```

---

### Module: `modules/iam`

| File           | Purpose                                                                 |
| -------------- | ----------------------------------------------------------------------- |
| `variables.tf` | `role_name` (string), `policy_arns` (list), `service_principals` (list) |
| `main.tf`      | `aws_iam_role.this` + `aws_iam_role_policy_attachment.this` (for_each)  |
| `outputs.tf`   | `role_arn`, `role_name`                                                 |

**Usage in root:** Called three times:

| Instance                      | Role Name                                  | Service Principal       | Policies                                      |
| ----------------------------- | ------------------------------------------ | ----------------------- | --------------------------------------------- |
| `lambda_execution_role`       | `ReadmeGeneratorLambdaExecutionRole`       | `lambda.amazonaws.com`  | `AWSLambdaBasicExecutionRole`                 |
| `orchestrator_execution_role` | `ReadmeGeneratorOrchestratorExecutionRole` | `lambda.amazonaws.com`  | `AWSLambdaBasicExecutionRole` + custom inline |
| `bedrock_agent_role`          | `ReadmeGeneratorBedrockAgentRole`          | `bedrock.amazonaws.com` | `AmazonBedrockFullAccess`                     |

---

### Module: `modules/bedrock_agent`

| File           | Purpose                                                                                               |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| `variables.tf` | `agent_name`, `foundation_model` (default: Claude 3 Sonnet), `instruction`, `agent_resource_role_arn` |
| `main.tf`      | `aws_bedrockagent_agent.this`                                                                         |
| `outputs.tf`   | `agent_id`, `agent_name`, `agent_arn`                                                                 |

**Usage in root:** Called five times (one per agent):

| Instance                   | Agent Name                 |
| -------------------------- | -------------------------- |
| `repo_scanner_agent`       | `Repo_Scanner_Agent`       |
| `project_summarizer_agent` | `Project_Summarizer_Agent` |
| `installation_guide_agent` | `Installation_Guide_Agent` |
| `usage_examples_agent`     | `Usage_Examples_Agent`     |
| `final_compiler_agent`     | `Final_Compiler_Agent`     |

---

## Root-Level Resources (not in modules)

These resources are defined directly in `main.tf` because they are one-off or have complex dependencies:

| Resource                                                | Type              | Purpose                                                |
| ------------------------------------------------------- | ----------------- | ------------------------------------------------------ |
| `random_string.suffix`                                  | `random_string`   | Unique suffix for S3 bucket name                       |
| `archive_file.repo_scanner_zip`                         | `archive_file`    | Packages `src/repo_scanner/` → `dist/repo_scanner.zip` |
| `archive_file.orchestrator_zip`                         | `archive_file`    | Packages `src/orchestrator/` → `dist/orchestrator.zip` |
| `aws_lambda_function.repo_scanner_lambda`               | Lambda            | RepoScannerTool (30s timeout, git layer)               |
| `aws_lambda_function.orchestrator_lambda`               | Lambda            | Orchestrator (180s timeout, 10 env vars)               |
| `aws_iam_policy.orchestrator_permissions`               | IAM Policy        | Bedrock invoke + S3 read/write on output bucket        |
| `aws_lambda_permission.allow_s3_to_invoke_orchestrator` | Lambda Permission | Allows S3 to trigger orchestrator                      |
| `aws_s3_bucket_notification.bucket_notification`        | S3 Notification   | Fires on `inputs/` prefix object creation              |
| `aws_s3_bucket.terraform_state`                         | S3 Bucket         | Remote Terraform state storage                         |
| `aws_dynamodb_table.terraform_locks`                    | DynamoDB          | State locking                                          |
| `aws_iam_role.github_actions_role`                      | IAM Role          | OIDC role for GitHub Actions                           |

---

## Provider Configuration

```hcl
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.5" }
  }
  backend "s3" {
    bucket         = "<state-bucket-name>"
    key            = "global/s3/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "readme-generator-tf-locks"
  }
}

provider "aws" {
  region = "us-east-1"
}
```

## Resource Count Summary

| Category         | Count                                                            |
| ---------------- | ---------------------------------------------------------------- |
| S3 Buckets       | 2 (output + state)                                               |
| DynamoDB Tables  | 1 (state locking)                                                |
| Lambda Functions | 2 (repo scanner + orchestrator)                                  |
| Bedrock Agents   | 5                                                                |
| IAM Roles        | 4 (scanner Lambda, orchestrator Lambda, Bedrock, GitHub Actions) |
| IAM Policies     | 1 custom + 4 managed attachments                                 |
