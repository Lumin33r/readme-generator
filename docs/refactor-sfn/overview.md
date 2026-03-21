# Refactor Overview — Step Functions Orchestration

## Summary

This refactor replaces the monolithic `ReadmeGeneratorOrchestrator` Lambda with an AWS
Step Functions **Express Workflow**. The Orchestrator Lambda currently owns a 180-second
execution budget for five sequential Bedrock agent calls. Three of those calls are
independent of each other and can run in parallel. The Orchestrator also mixes
infrastructure concerns (URL decoding, S3 event parsing) with business logic
(agent coordination) in one file.

After the refactor, each component has exactly one job.

---

## Current vs. Target Architecture

| Concern                           | Current Owner                     | New Owner                                  |
| --------------------------------- | --------------------------------- | ------------------------------------------ |
| Parse S3 event, decode URL        | Orchestrator Lambda               | `ParseS3Event` Lambda (bridge)             |
| Start the pipeline                | Orchestrator Lambda               | `ParseS3Event` → `sfn:StartExecution`      |
| Invoke RepoScanner agent          | Orchestrator Lambda (inline code) | SFN `ScanRepo` Task state                  |
| Invoke 3 analysis agents          | Orchestrator Lambda (sequential)  | SFN `AnalyzeInParallel` state (concurrent) |
| Invoke FinalCompiler agent        | Orchestrator Lambda (inline code) | SFN `CompileReadme` Task state             |
| Handle streaming Bedrock response | Orchestrator Lambda               | `AgentInvoker` Lambda (shared, thin)       |
| Assemble compiler input JSON      | Orchestrator Lambda (Python dict) | SFN `AssembleCompilerInput` Pass state     |
| Upload README to S3               | Orchestrator Lambda (boto3 call)  | SFN `UploadReadme` Task (direct S3 SDK)    |
| Retry on failure                  | None (swallowed as string)        | Per-state `Retry` policy in ASL            |
| Execution history                 | CloudWatch Logs grep              | Step Functions console (90-day history)    |

---

## Why Not Pure Direct Bedrock SDK Integration?

The design goal was to eliminate Lambda wrappers for agent calls. SSTM (SFN SDK
Integration) supports `bedrock-agent-runtime:invokeAgent` via the pattern:

```
arn:aws:states:::aws-sdk:bedrockagentruntime:invokeAgent
```

However, `InvokeAgent` returns an **HTTP/2 event stream** (`EventStream` type), not a
standard JSON response body. Step Functions SDK integrations read the response as a
single synchronous JSON document — they cannot consume a streaming EventStream.

**Result:** Calling `InvokeAgent` directly from a SFN Task state returns an empty or
unparseable response body; the actual text chunks are never received.

**Solution:** A single shared `AgentInvoker` Lambda (~35 lines) handles the streaming
consumption and returns a plain JSON object `{"result": "..."}`. This Lambda has no
business logic — it is a pure transport adapter. SFN calls it with different
`agent_id`/`input_text` parameters per state.

Direct SDK integration IS used for the final S3 `PutObject` call, which returns a
standard JSON response and requires no Lambda.

---

## Key Gains at a Glance

- **~40–60s faster** — three analysis agents run concurrently instead of sequentially
- **Per-step timeouts** — ScanRepo gets 90s; each analysis step gets 60s; no shared budget
- **Structured retry** — exponential backoff configured on each Task state, not silently swallowed
- **Visual audit trail** — Step Functions console shows every execution with per-state timing and I/O
- **Smaller, focused Lambda code** — Orchestrator Lambda deleted; replaced by two trivial functions

---

## Key Risks and Mitigations

| Risk                            | Likelihood | Mitigation                                                                                                                          |
| ------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 256 KB SFN state size limit     | Medium     | Large repos can produce verbose file lists + summaries. See [payload overflow pattern](./state-machine.md#payload-overflow-pattern) |
| ASL learning curve              | Low        | Full ASL definition is provided in `state-machine.md`                                                                               |
| IAM role creep (new roles)      | Low        | Two new roles documented in `infrastructure-changes.md`                                                                             |
| Bedrock `InvokeAgent` streaming | N/A        | Handled by `AgentInvoker` Lambda adapter                                                                                            |

---

## Component Map (After Refactor)

```
readme-generator/
├── src/
│   ├── repo_scanner/
│   │   └── lambda_function.py        # Unchanged — git clone + file list
│   ├── parse_s3_event/               # NEW — S3 event bridge → SFN
│   │   └── lambda_function.py
│   ├── agent_invoker/                # NEW — streaming adapter for Bedrock agents
│   │   └── lambda_function.py
│   └── sfn/                          # NEW — state machine definition
│       └── state_machine.asl.json
├── infra/
│   └── main.tf                       # Add SFN resources, remove Orchestrator resources
└── docs/
    └── refactor-sfn/
        ├── overview.md               (this file)
        ├── architecture-diagram.md
        ├── state-machine.md
        ├── infrastructure-changes.md
        └── implementation-plan.md
```
