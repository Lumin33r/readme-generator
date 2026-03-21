# Implementation Plan — AI README.md Generator

## Step-by-Step Build Order

This plan maps directly to the lab sequence, with each step producing a deployable increment.

### Step 1: Infrastructure Foundation (Lab 1)

**Goal:** Reusable Terraform modules + base AWS resources

- [ ] Create project structure: `main.tf`, `modules/`
- [ ] Build `modules/s3` (variables, resource, outputs)
- [ ] Build `modules/iam` (role + policy attachment with `for_each`)
- [ ] Wire up root `main.tf`: AWS provider, `random_string`, S3 bucket module, Lambda execution role, Bedrock agent role
- [ ] `terraform init && terraform apply`
- [ ] Validate: S3 bucket and IAM roles visible in AWS console
- [ ] Create `.gitignore` (Terraform state, dist/, venv/, etc.)

**Resources created:** 1 S3 bucket, 2 IAM roles

---

### Step 2: Repo Scanner Agent + Lambda Tool (Lab 2)

**Goal:** First Bedrock Agent with a Lambda-backed Action Group

- [ ] Write `src/repo_scanner/lambda_function.py` (git clone + file walk)
- [ ] Add `archive_file` + `aws_lambda_function` to root `main.tf` (with git layer)
- [ ] Create `repo_scanner_schema.json` (OpenAPI definition for `/scan-repo`)
- [ ] Build `modules/bedrock_agent` (variables, resource, outputs)
- [ ] Add `module "repo_scanner_agent"` with Action Group referencing the Lambda + schema
- [ ] `terraform apply`
- [ ] Test in Bedrock console with a sample GitHub URL

**Resources created:** 1 Lambda function, 1 Bedrock Agent (with Action Group)

---

### Step 3: Analytical Agents (Lab 3)

**Goal:** Three prompt-only agents for analysis

- [ ] Add `module "project_summarizer_agent"` with summary prompt
- [ ] Add `module "installation_guide_agent"` with install detection prompt
- [ ] Add `module "usage_examples_agent"` with entry-point detection prompt
- [ ] `terraform apply`
- [ ] Test each agent individually in Bedrock console with mock file list JSON

**Resources created:** 3 Bedrock Agents

---

### Step 4: Orchestrator + Compiler (Lab 4)

**Goal:** End-to-end pipeline triggered by S3 upload

- [ ] Add `module "final_compiler_agent"` with compilation prompt
- [ ] Write `src/orchestrator/lambda_function.py` (sequential agent invocation chain)
- [ ] Add `module "orchestrator_execution_role"` (IAM) with custom Bedrock + S3 policy
- [ ] Add `archive_file` + `aws_lambda_function` for orchestrator (180s timeout, 10 env vars)
- [ ] Add S3 event notification (`inputs/` prefix → orchestrator Lambda)
- [ ] `terraform apply`
- [ ] End-to-end test: `aws s3 cp` trigger file → check `outputs/` for README.md

**Resources created:** 1 Bedrock Agent, 1 Lambda function, 1 IAM role + policy, S3 notification config

---

### Step 5: Prompt Refinement (Lab 5)

**Goal:** Production-quality README output

- [ ] Update `project_summarizer_agent` prompt: remove hedging language
- [ ] Update `installation_guide_agent` prompt: one-shot example with code block
- [ ] Update `usage_examples_agent` prompt: one-shot example with code block
- [ ] Update `final_compiler_agent` prompt: strict anti-filler/anti-preamble constraints
- [ ] `terraform apply`
- [ ] Re-trigger workflow and compare output quality

**Resources changed:** 4 Bedrock Agent instruction updates (in-place)

---

### Step 6: CI/CD Automation (Lab 6)

**Goal:** Fully automated deploy + test on push to main

- [ ] Add S3 state bucket + DynamoDB lock table to `main.tf`
- [ ] `terraform apply` → create backend resources
- [ ] Create `backend.tf` with state bucket name
- [ ] `terraform init` → migrate state to S3
- [ ] Add OIDC provider data source + GitHub Actions IAM role to `main.tf`
- [ ] `terraform apply`
- [ ] Create `.github/workflows/deploy.yml` (checkout → OIDC auth → init → apply → trigger test)
- [ ] Add `AWS_IAM_ROLE_ARN` to GitHub Secrets
- [ ] `git push` → verify pipeline runs in GitHub Actions tab

**Resources created:** 1 S3 bucket (state), 1 DynamoDB table, 1 IAM role (OIDC)

---

## Open Questions / Risks

| Risk                                                                  | Impact                                                | Mitigation                                                     |
| --------------------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------- |
| Bedrock Claude model access not enabled                               | No agents work                                        | Must enable Anthropic Claude in Bedrock console before Lab 2   |
| Lambda 180s timeout may not be enough for large repos + 5 agent calls | Orchestrator times out                                | Monitor CloudWatch Duration metric; increase timeout if needed |
| `TSTALIASID` test alias has no versioning                             | Agent changes take effect immediately                 | Acceptable for lab; production would use versioned aliases     |
| `AdministratorAccess` on GitHub Actions role                          | Overly broad permissions                              | Replace with least-privilege custom policy for production      |
| No retry logic in orchestrator                                        | Single agent failure = full pipeline failure          | Add per-agent retry with backoff for production use            |
| URL encoding scheme is fragile                                        | Repos with hyphens in org/name may decode incorrectly | Current decode logic handles the first two hyphens only        |
