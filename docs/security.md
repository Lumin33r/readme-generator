# Security — AI README.md Generator

## IAM Roles & Least Privilege

The system uses four separate IAM roles, each scoped to a single responsibility:

### Role 1: `ReadmeGeneratorLambdaExecutionRole`

| Property        | Value                         |
| --------------- | ----------------------------- |
| Trust Principal | `lambda.amazonaws.com`        |
| Managed Policy  | `AWSLambdaBasicExecutionRole` |
| Used By         | `RepoScannerTool` Lambda      |

Grants only CloudWatch Logs permissions (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`). The Repo Scanner Lambda does not need S3 or Bedrock access — it only clones repos and returns file lists.

### Role 2: `ReadmeGeneratorOrchestratorExecutionRole`

| Property        | Value                               |
| --------------- | ----------------------------------- |
| Trust Principal | `lambda.amazonaws.com`              |
| Managed Policy  | `AWSLambdaBasicExecutionRole`       |
| Custom Policy   | `ReadmeGeneratorOrchestratorPolicy` |

Custom policy grants:

- `bedrock:InvokeAgent` and `bedrock-agent-runtime:InvokeAgent` on `*` (required — agent ARNs are dynamic)
- `s3:GetObject`, `s3:PutObject`, `s3:HeadObject` scoped to `${bucket_arn}/*` (output bucket only)

### Role 3: `ReadmeGeneratorBedrockAgentRole`

| Property        | Value                     |
| --------------- | ------------------------- |
| Trust Principal | `bedrock.amazonaws.com`   |
| Managed Policy  | `AmazonBedrockFullAccess` |
| Used By         | All 5 Bedrock Agents      |

Shared across all agents. Grants the Bedrock service permission to invoke foundation models on behalf of the agents.

### Role 4: `GitHubActionsRole-ReadmeGenerator`

| Property        | Value                                                                    |
| --------------- | ------------------------------------------------------------------------ |
| Trust Principal | Federated (OIDC — `token.actions.githubusercontent.com`)                 |
| Condition       | `StringEquals` on `sub` claim: `repo:<owner>/<repo>:ref:refs/heads/main` |
| Managed Policy  | `AdministratorAccess`                                                    |

**Note:** `AdministratorAccess` is used for lab simplicity. In production, this should be replaced with a custom policy granting only the Terraform actions needed (S3, IAM, Lambda, Bedrock, DynamoDB).

---

## Authentication

### GitHub Actions → AWS (OIDC)

No long-lived AWS credentials are stored in GitHub. The pipeline uses OpenID Connect federation:

1. GitHub Actions requests an OIDC token from `token.actions.githubusercontent.com`
2. The token's `sub` claim encodes the repo and branch (`repo:Owner/Repo:ref:refs/heads/main`)
3. AWS STS validates the token against the registered OIDC provider
4. The `GitHubActionsRole` trust policy checks the `sub` claim matches the expected repo
5. Temporary credentials are issued for the pipeline run

**Branch restriction:** Only the `main` branch can assume this role (enforced by the `StringEquals` condition).

### Lambda → Bedrock (IAM)

Lambda functions authenticate to Bedrock using their execution role's temporary credentials (no API keys, no secrets).

---

## Input Validation & Safety

| Concern                   | Mitigation                                                                                                                        |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Malicious repo URLs       | Repo Scanner only clones public repos via `git clone`; Lambda runs in an isolated sandbox with no network access beyond the clone |
| Command injection via URL | The URL is passed as a single argument to `subprocess.run()` — not interpolated into a shell command                              |
| Large repositories        | Lambda timeout (30s) and `/tmp` storage limit (512 MB) naturally cap clone size                                                   |
| S3 key injection          | Filenames are decoded with a fixed pattern; output key uses only the last path segment (`repo_url.split('/')[-1]`)                |

---

## Secrets Management

| Secret             | Storage                                            | Access                      |
| ------------------ | -------------------------------------------------- | --------------------------- |
| AWS credentials    | None stored — OIDC for CI/CD, IAM roles for Lambda | Ephemeral STS tokens        |
| `AWS_IAM_ROLE_ARN` | GitHub Actions secret                              | Referenced in workflow YAML |
| Terraform state    | S3 bucket (server-side encryption by default)      | IAM role with S3 access     |

---

## Network Security

All components run within AWS managed services — no VPC, no public endpoints, no inbound traffic:

- **Lambda functions:** Run in AWS-managed VPC (default). No customer VPC configuration needed.
- **S3 buckets:** Accessed via AWS SDK (IAM-authenticated). No public access configured.
- **Bedrock:** SaaS API — accessed via SDK with IAM credentials.
- **Git clones:** Outbound HTTPS only (Lambda default — no NAT gateway needed for public repos).
