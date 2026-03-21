terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "us-west-2" # You can change this to your preferred region
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ---------------------------------------------------------------------------
# VPC — use the account's default VPC; no new network resources required.
# All subnets in the default VPC are public, so assign_public_ip must be true
# for ECS Fargate tasks to pull images and the Lambda to reach the internet.
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

# The default route (0.0.0.0/0 → IGW) was removed from the main route table.
# Restore it so ECS tasks can reach Secrets Manager, DockerHub, and other
# internet endpoints needed for Fargate to start containers.
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_route" "default_internet" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.default.id
}

# Discover the one existing subnet in the default VPC.
# The default VPC has a single /16 subnet (172.31.0.0/16) in us-west-2c;
# address space is exhausted so no additional default subnets can be created.
# The NLBs (both OTEL and Grafana) and ECS tasks all run in this subnet.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  default_subnet_ids = data.aws_subnets.default.ids
}

# Generate a secure Grafana admin password automatically.
# Retrieve after apply: aws secretsmanager get-secret-value --secret-id readme-generator/obs/grafana-admin
resource "random_password" "grafana_admin" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>?"
}

module "s3_bucket" {
  source      = "./modules/s3"
  bucket_name = "readme-generator-output-bucket-${random_string.suffix.result}"
}


# Role specifically for the Lambda function to run
module "lambda_execution_role" {
  source             = "./modules/iam"
  role_name          = "ReadmeGeneratorLambdaExecutionRole_troy"
  service_principals = ["lambda.amazonaws.com"]
  policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
}

# Role specifically for the Bedrock Agent to use
module "bedrock_agent_role" {
  source             = "./modules/iam"
  role_name          = "ReadmeGeneratorBedrockAgentRole_troy"
  service_principals = ["bedrock.amazonaws.com"]
  policy_arns = [
    "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  ]
}

output "readme_bucket_name" {
  description = "The name of the S3 bucket where README files are stored."
  value       = module.s3_bucket.bucket_id
}

output "state_machine_arn" {
  description = "The ARN of the ReadmeGeneratorPipeline Step Functions state machine."
  value       = aws_sfn_state_machine.readme_generator.arn
}

# Add these new resources at the end of your file

# main.tf
data "archive_file" "repo_scanner_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/repo_scanner"
  output_path = "${path.root}/../dist/repo_scanner.zip"
}

resource "aws_lambda_function" "repo_scanner_lambda" {
  function_name    = "RepoScannerTool"
  role             = module.lambda_execution_role.role_arn # Uses the dedicated Lambda role
  filename         = data.archive_file.repo_scanner_zip.output_path
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 60 # Increased for shallow-cloning large repos
  source_code_hash = data.archive_file.repo_scanner_zip.output_base64sha256

  # This line adds the 'git' command to our Lambda environment
  layers = ["arn:aws:lambda:us-west-2:553035198032:layer:git-lambda2:8"]
}

# Add these new resources at the end of your file

module "repo_scanner_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Repo_Scanner_Agent"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn # Uses the dedicated Bedrock role
  instruction             = "Your job is to use the scan_repo tool to get a file list from a public GitHub URL. You are a helpful AI assistant. When a user provides a GitHub URL, you must use the available tool to scan it."
}

resource "aws_bedrockagent_agent_action_group" "repo_scanner_action_group" {
  agent_id                   = module.repo_scanner_agent.agent_id
  agent_version              = "DRAFT"
  action_group_name          = "ScanRepoAction"
  action_group_state         = "ENABLED"
  skip_resource_in_use_check = true

  action_group_executor {
    lambda = aws_lambda_function.repo_scanner_lambda.arn
  }

  api_schema {
    payload = file("${path.root}/../repo_scanner_schema.json")
  }
}

# This resource grants the Bedrock Agent permission to invoke our Lambda function
resource "aws_lambda_permission" "allow_bedrock_to_invoke_lambda" {
  statement_id  = "AllowBedrockToInvokeRepoScannerLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.repo_scanner_lambda.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = module.repo_scanner_agent.agent_arn
}

# root/main.tf

module "project_summarizer_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Project_Summarizer_Agent"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are an expert software developer writing a project summary for a README.md.
    Analyze the provided file list and write a confident, factual summary of the project's purpose and key components.
    **Do not use uncertain or hedging language** like 'it appears to be,' 'likely,' or 'seems to be.' State your analysis as fact.
    Your response must be only the summary paragraph.
  EOT
}

# root/main.tf

module "installation_guide_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Installation_Guide_Agent"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are a technical writer creating a README.md. Your ONLY job is to scan the provided list of filenames.
    If you see a common dependency file, write a '## Installation' section in Markdown.
    Your response must be concise and contain ONLY the command.
    For example, if you see 'requirements.txt', your entire response MUST be:
    ## Installation
    `
    `
    `bash
    pip install -r requirements.txt
    `
    `
    `
    If you do not see any recognizable dependency files, respond with an empty string.
  EOT
}

# root/main.tf

module "usage_examples_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Usage_Examples_Agent"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are a software developer writing a README.md. Your ONLY task is to identify the most likely entry point from a list of filenames.
    Write a '## Usage' section in Markdown showing the command to run the project.
    Your response MUST be concise and wrap the command in a bash code block.
    For example, if you see 'main.py', your entire response MUST be:
    ## Usage
    `
    `
    `bash
    python main.py
    `
    `
    `
  EOT
}

# root/main.tf

# root/main.tf

module "final_compiler_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Final_Compiler_Agent"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are a technical document compiler. Your task is to take a JSON object containing different sections of a README file and assemble them into a single Markdown document.
    Use the repository name for the main H1 header (e.g., # repository_name).
    Combine the other sections provided.
    Your output MUST be only the pure, complete Markdown document.
    Do NOT include any preamble, apologies, explanations of your process, or any conversational text.
  EOT
}

# =============================================================================
# STEP FUNCTIONS ORCHESTRATION — replaces ReadmeGeneratorOrchestrator Lambda
# =============================================================================

# --- AgentInvoker Lambda (streaming adapter for Bedrock Agent Runtime) ---

# Install OTEL dependencies into a clean build directory so the Lambda zip
# includes them without polluting src/agent_invoker/ with installed packages.
locals {
  agent_invoker_src   = "${abspath(path.root)}/../src/agent_invoker"
  agent_invoker_build = "${abspath(path.root)}/../dist/agent_invoker_build"
}

resource "null_resource" "agent_invoker_build" {
  triggers = {
    requirements = filesha256("${local.agent_invoker_src}/requirements.txt")
    source       = filesha256("${local.agent_invoker_src}/lambda_function.py")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-ec"]
    command     = <<-CMD
      rm -rf "${local.agent_invoker_build}"
      mkdir -p "${local.agent_invoker_build}"
      pip install -r "${local.agent_invoker_src}/requirements.txt" \
        -t "${local.agent_invoker_build}" --quiet
      cp "${local.agent_invoker_src}/lambda_function.py" "${local.agent_invoker_build}/"
    CMD
  }
}

data "archive_file" "agent_invoker_zip" {
  depends_on  = [null_resource.agent_invoker_build]
  type        = "zip"
  source_dir  = local.agent_invoker_build
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

# Allow the Lambda to create ENIs so it can run inside the VPC and reach the
# OTEL Collector NLB over a private IP address.
resource "aws_iam_role_policy_attachment" "agent_invoker_vpc" {
  role       = aws_iam_role.agent_invoker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# VPC Interface Endpoint for Bedrock Agent Runtime.
# Lambda in VPC has no public IP so cannot reach AWS services over the internet.
# This endpoint allows private connectivity to bedrock-agent-runtime.
resource "aws_security_group" "bedrock_endpoint" {
  name        = "ReadmeGeneratorBedrockEndpointSG"
  description = "Allow HTTPS from Lambda to Bedrock VPC endpoint"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS from Agent Invoker Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.agent_invoker_lambda.id]
  }
}

resource "aws_vpc_endpoint" "bedrock_agent_runtime" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.us-west-2.bedrock-agent-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.default_subnet_ids
  security_group_ids  = [aws_security_group.bedrock_endpoint.id]
  private_dns_enabled = true
}

# Security group for the Agent Invoker Lambda.
# No inbound rules needed; the Lambda only initiates outbound connections.
resource "aws_security_group" "agent_invoker_lambda" {
  name        = "ReadmeGeneratorAgentInvokerSG"
  description = "Agent Invoker Lambda - egress to OTEL Collector NLB and Bedrock"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lambda_function" "agent_invoker" {
  function_name    = "ReadmeGeneratorAgentInvoker"
  role             = aws_iam_role.agent_invoker_role.arn
  filename         = data.archive_file.agent_invoker_zip.output_path
  source_code_hash = data.archive_file.agent_invoker_zip.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 300

  # Place the Lambda in the default VPC so it can reach the OTEL Collector
  # NLB via a private IP address.  Subnets are public (default VPC only has
  # public subnets), so the Lambda still has internet access for Bedrock.
  vpc_config {
    subnet_ids         = local.default_subnet_ids
    security_group_ids = [aws_security_group.agent_invoker_lambda.id]
  }

  environment {
    variables = {
      OTEL_EXPORTER_OTLP_ENDPOINT = module.observability.otel_collector_endpoint
      OTEL_SERVICE_NAME           = "readme-generator-agent-invoker"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.agent_invoker_logs,
    aws_iam_role_policy_attachment.agent_invoker_vpc,
  ]
}

# --- Step Functions Execution Role ---

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

resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/ReadmeGeneratorPipeline"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "agent_invoker_logs" {
  name              = "/aws/lambda/ReadmeGeneratorAgentInvoker"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "parse_s3_event_logs" {
  name              = "/aws/lambda/ReadmeGeneratorParseS3Event"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "readme_generator" {
  name     = "ReadmeGeneratorPipeline"
  role_arn = aws_iam_role.sfn_execution_role.arn
  type     = "EXPRESS"

  definition = templatefile("${path.root}/../src/sfn/state_machine.asl.json", {
    AgentInvokerFunctionArn = aws_lambda_function.agent_invoker.arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ALL" # ALL required for test_all_states_entered in eval suite
  }
}

# --- ParseS3Event Lambda (S3 → SFN bridge) ---

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
      STATE_MACHINE_ARN                 = aws_sfn_state_machine.readme_generator.arn
      OUTPUT_BUCKET                     = module.s3_bucket.bucket_id
      REPO_SCANNER_AGENT_ID             = module.repo_scanner_agent.agent_id
      REPO_SCANNER_AGENT_ALIAS_ID       = "TSTALIASID"
      PROJECT_SUMMARIZER_AGENT_ID       = module.project_summarizer_agent.agent_id
      PROJECT_SUMMARIZER_AGENT_ALIAS_ID = "TSTALIASID"
      INSTALLATION_GUIDE_AGENT_ID       = module.installation_guide_agent.agent_id
      INSTALLATION_GUIDE_AGENT_ALIAS_ID = "TSTALIASID"
      USAGE_EXAMPLES_AGENT_ID           = module.usage_examples_agent.agent_id
      USAGE_EXAMPLES_AGENT_ALIAS_ID     = "TSTALIASID"
      FINAL_COMPILER_AGENT_ID           = module.final_compiler_agent.agent_id
      FINAL_COMPILER_AGENT_ALIAS_ID     = "TSTALIASID"
    }
  }
}

resource "aws_lambda_permission" "allow_s3_to_invoke_parse" {
  statement_id  = "AllowS3ToInvokeParseS3EventLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parse_s3_event.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.s3_bucket.bucket_arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = module.s3_bucket.bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.parse_s3_event.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inputs/"
  }

  depends_on = [aws_lambda_permission.allow_s3_to_invoke_parse]
}

# S3 lifecycle rules for observability data written by Loki and Tempo.
# These rules are activated once the observability module is deployed and
# the services begin writing to obs/loki/ and obs/tempo/ prefixes.
resource "aws_s3_bucket_lifecycle_configuration" "obs_retention" {
  bucket = module.s3_bucket.bucket_id

  rule {
    id     = "loki-retention"
    status = "Enabled"
    filter { prefix = "obs/loki/" }
    expiration { days = 30 }
  }

  rule {
    id     = "tempo-retention"
    status = "Enabled"
    filter { prefix = "obs/tempo/" }
    expiration { days = 14 }
  }
}

# Add to main.tf

# --- NEW RESOURCES FOR CI/CD PIPELINE ---

resource "random_string" "state_bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "tf-readme-generator-state-${random_string.state_bucket_suffix.result}"
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "readme-generator-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "terraform_state_bucket_name" {
  description = "The name of the S3 bucket for the Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}

# Add to main.tf

# Find the existing OIDC provider for GitHub in the AWS account.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_trust_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # This line ensures ONLY your specific repo can use this role
      values = ["repo:https://github.com/Lumin33r/readme-generator:ref:refs/heads/main"]
    }
  }
}

# This is a NEW role, separate from your Lambda and Bedrock roles.
# Its only job is to give GitHub Actions permission to run 'terraform apply'.
resource "aws_iam_role" "github_actions_role" {
  name               = "GitHubActionsRole-ReadmeGenerator"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust_policy.json
}

resource "aws_iam_role_policy_attachment" "github_actions_permissions" {
  role = aws_iam_role.github_actions_role.name
  # NOTE: In a production environment, you would create a custom, least-privilege policy.
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Add this new output to your outputs.tf or main.tf
output "github_actions_role_arn" {
  description = "The ARN of the IAM role for GitHub Actions."
  value       = aws_iam_role.github_actions_role.arn
}

# =============================================================================
# OBSERVABILITY MODULE
# Grafana + Prometheus + Loki + Tempo + OTEL Collector on ECS Fargate.
# Uses the default VPC; both private_subnet_ids and public_subnet_ids receive
# the same public subnet list because the default VPC has no private subnets.
# assign_public_ip = true lets ECS tasks pull images without a NAT gateway.
# =============================================================================

module "observability" {
  source = "./modules/observability"

  name_prefix = "readme-generator"
  aws_region  = "us-west-2"

  vpc_id             = data.aws_vpc.default.id
  private_subnet_ids = local.default_subnet_ids
  public_subnet_ids  = local.default_subnet_ids
  assign_public_ip   = true # Required: default VPC subnets are public only

  shared_s3_bucket_id  = module.s3_bucket.bucket_id
  shared_s3_bucket_arn = module.s3_bucket.bucket_arn

  grafana_admin_password = random_password.grafana_admin.result

  tags = {
    Project   = "readme-generator"
    ManagedBy = "terraform"
  }
}

output "grafana_url" {
  description = "URL of the Grafana dashboard."
  value       = module.observability.grafana_url
}

output "otel_collector_endpoint" {
  description = "OTLP HTTP endpoint for the OTEL Collector NLB (used by Lambda)."
  value       = module.observability.otel_collector_endpoint
}

# ---------------------------------------------------------------------------
# CloudWatch → Loki forwarder Lambda
# Receives CW Logs subscription filter events and pushes them to Loki's HTTP
# push API.  Runs inside the default VPC to reach loki.obs.local:3100.
# ---------------------------------------------------------------------------

data "archive_file" "cw_to_loki_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../src/cw_to_loki"
  output_path = "${path.root}/../dist/cw_to_loki.zip"
}

resource "aws_iam_role" "cw_to_loki_role" {
  name = "ReadmeGeneratorCWToLokiRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_to_loki_basic" {
  role       = aws_iam_role.cw_to_loki_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cw_to_loki_vpc" {
  role       = aws_iam_role.cw_to_loki_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "cw_to_loki" {
  name        = "ReadmeGeneratorCWToLokiSG"
  description = "CW-to-Loki forwarder Lambda egress to Loki on port 3100"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Allow the forwarder Lambda to reach Loki tasks on port 3100
resource "aws_security_group_rule" "loki_from_forwarder" {
  type                     = "ingress"
  description              = "Loki HTTP push from CW forwarder Lambda"
  from_port                = 3100
  to_port                  = 3100
  protocol                 = "tcp"
  security_group_id        = module.observability.obs_internal_sg_id
  source_security_group_id = aws_security_group.cw_to_loki.id
}

resource "aws_cloudwatch_log_group" "cw_to_loki_logs" {
  name              = "/aws/lambda/ReadmeGeneratorCWToLoki"
  retention_in_days = 7
}

resource "aws_lambda_function" "cw_to_loki" {
  function_name    = "ReadmeGeneratorCWToLoki"
  role             = aws_iam_role.cw_to_loki_role.arn
  filename         = data.archive_file.cw_to_loki_zip.output_path
  source_code_hash = data.archive_file.cw_to_loki_zip.output_base64sha256
  handler          = "lambda_function.handler"
  runtime          = "python3.11"
  timeout          = 30

  vpc_config {
    subnet_ids         = local.default_subnet_ids
    security_group_ids = [aws_security_group.cw_to_loki.id]
  }

  environment {
    variables = {
      LOKI_PUSH_URL = module.observability.loki_push_url
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.cw_to_loki_logs,
    aws_iam_role_policy_attachment.cw_to_loki_vpc,
  ]
}

# Allow CloudWatch Logs service to invoke the forwarder Lambda
resource "aws_lambda_permission" "cw_invoke_forwarder_agent_invoker" {
  statement_id  = "AllowCWLogsAgentInvoker"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cw_to_loki.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.agent_invoker_logs.arn}:*"
}

resource "aws_lambda_permission" "cw_invoke_forwarder_sfn" {
  statement_id  = "AllowCWLogsSFN"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cw_to_loki.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
}

resource "aws_lambda_permission" "cw_invoke_forwarder_parse_s3" {
  statement_id  = "AllowCWLogsParseS3Event"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cw_to_loki.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.parse_s3_event_logs.arn}:*"
}

# Subscription filters — push each log group to the forwarder Lambda
resource "aws_cloudwatch_log_subscription_filter" "agent_invoker_to_loki" {
  name            = "readme-generator-agent-invoker-to-loki"
  log_group_name  = aws_cloudwatch_log_group.agent_invoker_logs.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.cw_to_loki.arn
  depends_on      = [aws_lambda_permission.cw_invoke_forwarder_agent_invoker]
}

resource "aws_cloudwatch_log_subscription_filter" "sfn_to_loki" {
  name            = "readme-generator-sfn-to-loki"
  log_group_name  = aws_cloudwatch_log_group.sfn_logs.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.cw_to_loki.arn
  depends_on      = [aws_lambda_permission.cw_invoke_forwarder_sfn]
}

resource "aws_cloudwatch_log_subscription_filter" "parse_s3_event_to_loki" {
  name            = "readme-generator-parse-s3-event-to-loki"
  log_group_name  = aws_cloudwatch_log_group.parse_s3_event_logs.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.cw_to_loki.arn
  depends_on      = [aws_lambda_permission.cw_invoke_forwarder_parse_s3]
}

