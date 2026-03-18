# Observability — AI README.md Generator

## Logging

All observability comes through **Amazon CloudWatch Logs**, which Lambda writes to automatically via the `AWSLambdaBasicExecutionRole` policy.

### Log Groups

| Log Group                                 | Source              | Key Events                                                |
| ----------------------------------------- | ------------------- | --------------------------------------------------------- |
| `/aws/lambda/RepoScannerTool`             | Repo Scanner Lambda | Clone success/failure, file count                         |
| `/aws/lambda/ReadmeGeneratorOrchestrator` | Orchestrator Lambda | Full event payload, each agent response, S3 upload result |

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
