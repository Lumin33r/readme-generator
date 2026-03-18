# System Context — AI README.md Generator

## Actors

| Actor                | Type         | Interaction                                                                |
| -------------------- | ------------ | -------------------------------------------------------------------------- |
| Developer / Ops User | Human        | Uploads encoded repo URL file to S3 `inputs/` prefix (manual trigger)      |
| GitHub Actions       | Automated    | Pushes code → pipeline runs `terraform apply` → uploads trigger file to S3 |
| AWS S3               | Event Source | `s3:ObjectCreated:*` on `inputs/` prefix fires Lambda notification         |
| Orchestrator Lambda  | Compute      | Receives S3 event, coordinates all agent invocations                       |
| Bedrock Agents (x5)  | AI           | Each agent performs a specialized analysis or compilation task             |
| Repo Scanner Lambda  | Tool         | Called by `Repo_Scanner_Agent` via Action Group to clone a public repo     |

## External Dependencies

| Dependency                       | Purpose                                      | Failure Impact                                          |
| -------------------------------- | -------------------------------------------- | ------------------------------------------------------- |
| Public GitHub repos              | Source of repos to analyze                   | Workflow fails if repo is private or URL is malformed   |
| Amazon Bedrock (Claude 3 Sonnet) | Foundation model for all 5 agents            | Complete workflow failure; no fallback model configured |
| Git Lambda Layer                 | Provides `git` binary to Repo Scanner Lambda | Cannot clone repos without it                           |
| GitHub OIDC Provider             | Keyless auth from GitHub Actions to AWS      | CI/CD pipeline cannot authenticate                      |

## System Boundary

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Account                              │
│                                                                 │
│  ┌──────────┐    S3 Event    ┌──────────────────┐               │
│  │ S3 Bucket │──────────────▶│ Orchestrator     │               │
│  │ inputs/   │               │ Lambda           │               │
│  │ outputs/  │◀──────────────│ (coordinator)    │               │
│  └──────────┘   PutObject    └───────┬──────────┘               │
│                                      │                          │
│                              invoke_agent() x5                  │
│                                      │                          │
│                    ┌─────────────────┼─────────────────┐        │
│                    ▼                 ▼                  ▼        │
│           ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│           │ Repo Scanner │  │ Summarizer   │  │ Compiler     │  │
│           │ Agent        │  │ Install Guide│  │ Agent        │  │
│           │ (+ Lambda    │  │ Usage Agent  │  │              │  │
│           │   tool)      │  │              │  │              │  │
│           └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                                 │
│  ┌────────────────────────────────────────┐                     │
│  │ Terraform State: S3 + DynamoDB Lock    │                     │
│  └────────────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────────────┘
         ▲                                          ▲
         │ s3 cp (trigger file)                     │ OIDC assume role
         │                                          │
    ┌────┴─────┐                            ┌───────┴────────┐
    │ Developer│                            │ GitHub Actions │
    └──────────┘                            └────────────────┘
```

## Data Flow Summary

1. **Input:** An empty file named with an encoded GitHub URL (e.g., `https---github.com-User-Repo`) is uploaded to `s3://<bucket>/inputs/`.
2. **Processing:** The Orchestrator Lambda decodes the filename back to a URL, then sequentially invokes 5 Bedrock agents.
3. **Output:** A `README.md` file is written to `s3://<bucket>/outputs/<repo-name>/README.md`.
