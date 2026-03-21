# Archive — Pre-Refactor Documentation

These documents describe the **original monolithic Lambda orchestrator architecture**
(`ReadmeGeneratorOrchestrator`) that was replaced by the Step Functions pipeline in March 2026.

They are preserved for historical reference. The ADR capturing the decision to refactor is
at [`docs/adr/0002-step-functions-orchestration.md`](../adr/0002-step-functions-orchestration.md).

## Contents

| File                              | What it described                                                          |
| --------------------------------- | -------------------------------------------------------------------------- |
| `overview.md`                     | System summary — single Lambda calling 5 Bedrock agents sequentially       |
| `architecture-diagram.md`         | Mermaid diagram with `ReadmeGeneratorOrchestrator` as central coordinator  |
| `backend.md`                      | Lambda function roles, runtime, IAM notes                                  |
| `system-context.md`               | Actor/interaction table for the orchestrator-era pipeline                  |
| `data-architecture.md`            | S3 input/output layout (unchanged; S3 structure is the same post-refactor) |
| `api-design.md`                   | OpenAPI schema for the `RepoScannerTool` action group                      |
| `security.md`                     | IAM role breakdown for the four original roles                             |
| `implementation-plan.md`          | Lab build order for the original Terraform modules                         |
| `adr/0001-architecture-choice.md` | ADR accepting the initial serverless multi-agent Lambda design             |

## Current Architecture Docs

See the parent `docs/` directory:

- `refactor-sfn/` — SFN Express Workflow design (ASL, Terraform HCL, diagrams)
- `observability.md` + `otel-instrumentation.md` + `eval-strategy.md` + `terraform-module-plan.md` — observability plan
- `adr/0002-step-functions-orchestration.md` — decision record for the SFN refactor
