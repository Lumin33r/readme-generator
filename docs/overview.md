# Architecture Overview — AI README.md Generator

## Purpose

An event-driven, serverless system that accepts a public GitHub repository URL and produces a professional `README.md` file. Five specialized Amazon Bedrock agents collaborate in sequence — scanning the repo, analyzing its structure, and compiling the final document — orchestrated by an AWS Lambda function and triggered by an S3 upload event.

## Key Design Decisions

| Decision         | Choice                          | Rationale                                                                  |
| ---------------- | ------------------------------- | -------------------------------------------------------------------------- |
| Compute          | AWS Lambda (serverless)         | No long-running processes; each invocation is short-lived and event-driven |
| AI Runtime       | Amazon Bedrock Agents           | Managed agent orchestration with built-in tool-use (Action Groups)         |
| IaC              | Terraform with reusable modules | Repeatable deployments; modules for S3, IAM, Bedrock Agents                |
| Trigger Model    | S3 event notification           | Decouples input from processing; supports both manual and CI/CD triggers   |
| CI/CD            | GitHub Actions + OIDC           | Keyless authentication to AWS; automated deploy + test on push             |
| State Management | S3 + DynamoDB remote backend    | Safe for CI/CD; state locking prevents concurrent corruption               |

## Tech Stack

- **Infrastructure:** Terraform (HCL), AWS Provider ~> 5.0
- **Compute:** AWS Lambda (Python 3.11)
- **AI:** Amazon Bedrock (Claude 3 Sonnet), Bedrock Agent Runtime
- **Storage:** Amazon S3 (input triggers, output READMEs, Terraform state)
- **IAM:** Least-privilege roles for Lambda, Bedrock, and GitHub Actions (OIDC)
- **CI/CD:** GitHub Actions with OIDC federation
- **State Locking:** Amazon DynamoDB

## Project Structure (Final State)

```
readme-generator/
├── main.tf                         # Root Terraform config (all resources)
├── backend.tf                      # S3 remote state backend config
├── repo_scanner_schema.json        # OpenAPI schema for Repo Scanner tool
├── .gitignore
├── src/
│   ├── repo_scanner/
│   │   └── lambda_function.py      # Clones repo, lists files
│   └── orchestrator/
│       └── lambda_function.py      # Invokes all agents in sequence
├── dist/                           # Build artifacts (zips, gitignored)
├── modules/
│   ├── s3/                         # Reusable S3 bucket module
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── iam/                        # Reusable IAM role module
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── bedrock_agent/              # Reusable Bedrock Agent module
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── .github/
    └── workflows/
        └── deploy.yml              # CI/CD pipeline
```

## Lab-to-Architecture Mapping

| Lab   | What Gets Built                                                                 | Architecture Layer |
| ----- | ------------------------------------------------------------------------------- | ------------------ |
| Lab 1 | S3 module, IAM module, output bucket, Lambda + Bedrock roles                    | Infrastructure     |
| Lab 2 | Repo Scanner Lambda, OpenAPI schema, Bedrock Agent module, `Repo_Scanner_Agent` | Compute + AI       |
| Lab 3 | `Project_Summarizer_Agent`, `Installation_Guide_Agent`, `Usage_Examples_Agent`  | AI Agents          |
| Lab 4 | `Final_Compiler_Agent`, Orchestrator Lambda, S3 event trigger                   | Orchestration      |
| Lab 5 | Refined agent prompts (one-shot prompting, anti-filler constraints)             | AI Quality         |
| Lab 6 | Remote state backend, OIDC role, GitHub Actions workflow                        | CI/CD + Operations |
