# Deployment — AI README.md Generator

## Deployment Modes

### 1. Local Development (Manual)

```bash
# From the readme-generator/ root directory
terraform init          # Download providers, initialize backend
terraform plan          # Preview changes
terraform apply         # Deploy (interactive confirmation)
```

**Prerequisites:**

- AWS CLI configured with valid credentials
- Terraform installed (>= 1.0)
- Bedrock model access enabled (Anthropic Claude) in the AWS console

### 2. CI/CD Pipeline (GitHub Actions)

Triggered automatically on every push to `main`.

```yaml
# .github/workflows/deploy.yml
on:
  push:
    branches: [main]
```

**Pipeline stages:**

| Step | Action                                     | Purpose                                                         |
| ---- | ------------------------------------------ | --------------------------------------------------------------- |
| 1    | `actions/checkout@v4`                      | Clone repo                                                      |
| 2    | `aws-actions/configure-aws-credentials@v4` | OIDC auth → assume `GitHubActionsRole`                          |
| 3    | `hashicorp/setup-terraform@v3`             | Install Terraform                                               |
| 4    | `terraform init`                           | Initialize with S3 backend                                      |
| 5    | `terraform validate`                       | Syntax check                                                    |
| 6    | `terraform apply -auto-approve`            | Deploy all resources                                            |
| 7    | Run AI Workflow                            | Upload trigger file to S3 → generate README for the repo itself |

**Authentication:** OIDC federation (no stored AWS keys). The `AWS_IAM_ROLE_ARN` GitHub secret contains the role ARN.

---

## Deployment Order (First-Time Bootstrap)

The system must be deployed in two phases because the remote state backend must exist before it can be used:

### Phase 1: Bootstrap (Local Only)

1. Start with `main.tf` (no `backend.tf` yet) — local state
2. `terraform apply` creates:
   - Output S3 bucket
   - IAM roles (Lambda, Bedrock, Orchestrator)
   - State S3 bucket + DynamoDB lock table
3. Run `terraform output -raw terraform_state_bucket_name` → copy bucket name

### Phase 2: State Migration

4. Create `backend.tf` with the state bucket name
5. `terraform init` → responds with state migration prompt → type `yes`
6. Local `.tfstate` is now in S3

### Phase 3: Full Deployment

7. Continue adding resources (agents, Lambdas, S3 trigger, OIDC)
8. `terraform apply` after each lab
9. Once OIDC role exists, configure GitHub secret and push → CI/CD takes over

---

## Resource Packaging

Lambda functions are packaged as ZIP archives by Terraform's `archive_file` data source:

```
src/repo_scanner/lambda_function.py  →  dist/repo_scanner.zip
src/orchestrator/lambda_function.py  →  dist/orchestrator.zip
```

The `dist/` directory is gitignored — ZIPs are rebuilt on every `terraform apply`.

`source_code_hash` ensures Lambda is only redeployed when code changes:

```hcl
source_code_hash = data.archive_file.repo_scanner_zip.output_base64sha256
```

---

## Manual Workflow Trigger

After deployment, trigger the README generation pipeline by uploading a filename-encoded URL:

```bash
# 1. Get the bucket name
BUCKET=$(terraform output -raw readme_bucket_name)

# 2. Create the trigger file (empty)
touch https---github.com-TruLie13-municipal-ai

# 3. Upload to inputs/ prefix
aws s3 cp https---github.com-TruLie13-municipal-ai s3://$BUCKET/inputs/

# 4. Wait ~60 seconds, then check output
aws s3 cp s3://$BUCKET/outputs/municipal-ai/README.md ./generated-README.md
```

---

## Teardown

```bash
# Remove all AWS resources
terraform destroy

# Confirm with: yes
```

**Note:** The S3 state bucket and DynamoDB lock table are also destroyed. If you want to keep state history, remove the `backend.tf` first and migrate state back to local before destroying.
