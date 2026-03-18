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
  timeout          = 30 # Increased timeout for cloning
  source_code_hash = data.archive_file.repo_scanner_zip.output_base64sha256

  # This line adds the 'git' command to our Lambda environment
  layers = ["arn:aws:lambda:us-west-2:553035198032:layer:git-lambda2:8"]
}

# Add these new resources at the end of your file

module "repo_scanner_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Repo_Scanner_Agent_troy"
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

# prompt for the second agent that will analyze the file list and generate the README summary

module "project_summarizer_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Project_Summarizer_Agent_troy"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are an expert software developer. Your ONLY task is to analyze the following list of filenames and write a single, concise paragraph summarizing the project's likely purpose.
    Infer the main programming language and potential frameworks from file extensions and common project file names (e.g., 'pom.xml' implies Java/Maven, 'package.json' implies Node.js).
    Do not add any preamble or extra text. Only provide the summary paragraph.
  EOT
}

# prompt for the third agent that will analyze the file list and generate a 'Getting Started' section for the README

module "installation_guide_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Installation_Guide_Agent_troy"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are a technical writer. Your ONLY job is to scan the provided list of filenames.
    If you see a common dependency file like 'requirements.txt', 'package.json', 'pom.xml', or 'go.mod', write a '## Getting Started' section in Markdown that includes the standard command to install dependencies for that file type.
    If you do not see any recognizable dependency files, respond with the exact text: 'No dependency management file found.'
  EOT
}

# prompt for the fourth agent that will analyze the file list and generate a 'Usage' section for the README

module "usage_examples_agent" {
  source                  = "./modules/bedrock_agent"
  agent_name              = "Usage_Examples_Agent_troy"
  agent_resource_role_arn = module.bedrock_agent_role.role_arn
  instruction             = <<-EOT
    You are a software developer. Your ONLY task is to look at the list of filenames and identify the most likely main script or entry point (e.g., 'main.py', 'index.js', 'app.py').
    Write a '## Usage' section in Markdown that shows a common command to run the project.
    For example, if you see 'main.py', suggest 'python main.py'.
  EOT
}
