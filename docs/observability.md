# Observability Master Plan — README Generator

> **Status:** Post-SFN refactor. Replaces the single-Lambda observability model.
> This document is the index. See sibling docs for full detail on each layer.

## Signal Taxonomy

| Signal Type              | Source                                                | Destination              | Captured By              |
| ------------------------ | ----------------------------------------------------- | ------------------------ | ------------------------ |
| **Lambda metrics**       | CloudWatch Metrics (automatic)                        | Grafana → CW datasource  | Always-on                |
| **SFN execution events** | CloudWatch Logs `/aws/states/ReadmeGeneratorPipeline` | Loki                     | Always-on                |
| **Lambda logs**          | CloudWatch Logs `/aws/lambda/*`                       | Loki (CW exporter)       | Always-on                |
| **OTEL traces**          | `AgentInvoker` Lambda via OTEL SDK                    | Tempo                    | Requires instrumentation |
| **LLM span attributes**  | `AgentInvoker` (token count, cost, hashes)            | Tempo + Prometheus       | Requires instrumentation |
| **Eval scores**          | Post-execution eval Lambda or CI/CD suite             | Tempo (inline) + S3 (CI) | See eval doc             |

## Component Log Groups (Post-SFN)

| Log Group                                 | Source                    | Retention                   |
| ----------------------------------------- | ------------------------- | --------------------------- |
| `/aws/states/ReadmeGeneratorPipeline`     | SFN Express Workflow      | 14 days (Terraform-managed) |
| `/aws/lambda/ReadmeGeneratorParseS3Event` | S3→SFN bridge             | 14 days                     |
| `/aws/lambda/ReadmeGeneratorAgentInvoker` | Bedrock streaming adapter | 14 days                     |
| `/aws/lambda/RepoScannerTool`             | Bedrock action group      | 14 days                     |

## Related Documents

- [otel-instrumentation.md](otel-instrumentation.md) — Span design for AgentInvoker, attributes, token tracking
- [eval-strategy.md](eval-strategy.md) — CI/CD vs live eval layers, per-agent scoring
- [architecture-diagram.md](architecture-diagram.md) — Mermaid diagrams: context, trace hierarchy, CI/CD flow
- [terraform-module-plan.md](terraform-module-plan.md) — Full Grafana stack module structure and HCL skeleton

---

## Quick Debug Reference (Post-SFN)

### 1. Did ParseS3Event fire?

```bash
aws logs tail /aws/lambda/ReadmeGeneratorParseS3Event --since 10m --region us-west-2
```

### 2. Did the SFN execution start and what state did it fail in?

```bash
SFN_ARN=$(cd infra && terraform output -raw state_machine_arn)
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region us-west-2 --max-results 5
# Then inspect a specific execution:
aws stepfunctions get-execution-history \
  --execution-arn <arn> --region us-west-2
```

### 3. Which agent invocation failed?

```bash
aws logs tail /aws/lambda/ReadmeGeneratorAgentInvoker --since 10m --region us-west-2
```

### 4. Did the Repo Scanner timeout?

```bash
aws logs tail /aws/lambda/RepoScannerTool --since 10m --region us-west-2
```

### 5. Was the README uploaded?

```bash
BUCKET=$(cd infra && terraform output -raw readme_bucket_name)
aws s3 ls "s3://$BUCKET/outputs/" --recursive
```

### Orchestrator Debug Statements

The orchestrator includes structured debug logging at every stage:

```
[DEBUG] Bucket: readme-generator-output-bucket-ogdddih6
[DEBUG] Key: inputs/https---github.com-TruLie13-municipal-ai
[DEBUG] Repo URL: https://github.com/TruLie13/municipal-ai
[DEBUG] Output Bucket: readme-generator-output-bucket-ogdddih6
[DEBUG] Session ID: <request-id>
[DEBUG] Sanitized repo name: municipal-ai
[DEBUG] Output key: outputs/municipal-ai/README.md
[DEBUG] Starting agent invocation chain...
Invoking agent <agent-id> with input: <url>
Agent <agent-id> returned: <response>
...
Successfully uploaded README.md to s3://<bucket>/outputs/municipal-ai/README.md
```

### Repo Scanner Debug Statements

```
Cloning repository: https://github.com/TruLie13/municipal-ai
Repository cloned successfully.
```

On failure:

```
An error occurred. Git command failed with stderr: <error>
```

---

## Debugging Workflow

### Step 1: Check if the Orchestrator fired

```bash
aws logs tail /aws/lambda/ReadmeGeneratorOrchestrator --since 10m
```

If no logs, the S3 event notification may not be configured or the file wasn't uploaded to the `inputs/` prefix.

### Step 2: Check individual agent invocations

Search for agent invocation errors in the orchestrator logs:

```bash
aws logs filter-events \
  --log-group-name /aws/lambda/ReadmeGeneratorOrchestrator \
  --filter-pattern "Error invoking agent"
```

### Step 3: Check the Repo Scanner Lambda

```bash
aws logs tail /aws/lambda/RepoScannerTool --since 10m
```

Common failures: private repo (clone denied), very large repo (timeout at 30s), non-existent URL.

### Step 4: Verify output

```bash
aws s3 ls s3://<bucket>/outputs/<repo-name>/
```

---

## Metrics (Built-in)

No custom CloudWatch metrics are defined. The following AWS-provided metrics are available:

| Metric                 | Source | What to Watch                                  |
| ---------------------- | ------ | ---------------------------------------------- |
| `Invocations`          | Lambda | Should be 1 per trigger                        |
| `Duration`             | Lambda | Orchestrator typically 60-120s; Scanner ~5-15s |
| `Errors`               | Lambda | Any non-zero value indicates failure           |
| `Throttles`            | Lambda | Concurrent execution limit hit                 |
| `ConcurrentExecutions` | Lambda | Should be low (event-driven, not high-traffic) |

---

## Known Limitations

- No distributed tracing (X-Ray not enabled)
- No alerting configured (no SNS/CloudWatch Alarms)
- No structured JSON logging (print statements only)
- Agent-level metrics (token usage, latency per agent) are only visible in Bedrock console, not programmatically captured
