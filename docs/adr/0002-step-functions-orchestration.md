# ADR-0002: Replace Orchestrator Lambda with Step Functions Express Workflow

## Status

Proposed

## Context

The current `ReadmeGeneratorOrchestrator` Lambda (ADR-0001) is a "fat orchestrator":
it owns a single 180-second execution budget that must fit five sequential Bedrock agent
calls. Three of those calls — `Project_Summarizer_Agent`, `Installation_Guide_Agent`,
and `Usage_Examples_Agent` — all receive the same input and are independent of each
other. Running them sequentially wastes ~40–60 seconds per execution.

Additional problems observed in production (March 2026 debug session):

1. **KMS grant staleness:** When the IAM execution role was recreated by `terraform apply`,
   the Lambda's KMS grant pointed at the old Role ID, causing silent startup failures.
   The root cause is that Lambda's KMS grant is re-created only when the Lambda function
   itself is re-created. A Step Functions state machine has no per-function KMS grant
   dependency of this kind.

2. **Silent failure on error:** `invoke_agent_helper` catches all exceptions and returns
   the error string as content. This string flows into downstream agents and produces
   garbage output rather than a clean failure.

3. **No per-step observability:** All five invocations share one CloudWatch log stream,
   making it hard to isolate which agent caused a timeout or error.

4. **Tight timeout budget:** The 180s Lambda limit leaves ~6s of margin given the
   measured p95 of ~174s for a mid-size repo. Adding a sixth agent would break the limit.

## Decision

Replace the Orchestrator Lambda with an **AWS Step Functions Express Workflow**
(`ReadmeGeneratorPipeline`), keeping a small bridge Lambda (`ParseS3Event`) to translate
the S3 ObjectCreated event into a structured SFN execution input.

A shared thin **`AgentInvoker` Lambda** handles the streaming `InvokeAgent` response.
Direct SDK integration is not used for Bedrock agent calls because `InvokeAgent` returns
an HTTP/2 EventStream that SFN cannot parse natively. Direct SDK integration IS used for
the final `s3:PutObject` step.

The three independent analysis agents run in a SFN `Parallel` state (concurrent
branches) rather than sequentially.

## Options Considered

### Option A: Keep the Orchestrator Lambda, add `concurrent.futures`

Use Python's `ThreadPoolExecutor` inside the existing Orchestrator Lambda to parallelize
the three middle agent calls.

- **Pros:** Minimal infrastructure change; no new AWS resource types; teaches threading
- **Cons:** Doesn't fix the KMS grant problem; doesn't fix silent error swallowing;
  doesn't improve observability; Lambda timeout budget still shared across all calls;
  harder to add retries per-agent; the Orchestrator still does too many things

### Option B: Step Functions with pure direct SDK integration (no AgentInvoker Lambda)

Use `arn:aws:states:::aws-sdk:bedrockagentruntime:invokeAgent` as the Task resource
for every agent call, eliminating all Lambda wrappers.

- **Pros:** Cleanest architecture; no Lambda for agent calls at all
- **Cons:** `InvokeAgent` returns an EventStream — SFN SDK integration receives an
  empty/unparseable response body. This is not a configuration issue; it is a
  fundamental incompatibility between SFN's synchronous SDK integration model and
  streaming HTTP/2 responses. Cannot work without a streaming adapter.

### Option C: Step Functions with shared `AgentInvoker` Lambda (Selected)

SFN state machine calls one shared `AgentInvoker` Lambda (~35 lines) that handles
streaming. SFN owns all orchestration logic (parallel, retry, error branches, timeouts).
The `AgentInvoker` Lambda has no business logic — it is a pure I/O adapter.

- **Pros:** Fixes all four problems listed above; parallel execution; per-state timeouts;
  structured retries; visual execution history; AgentInvoker is stateless and trivially
  testable; does not require re-learning Bedrock agent infrastructure
- **Cons:** New resource type (SFN); ASL learning curve; 256 KB state size limit requires
  mitigation strategy for large repos (S3 intermediate store pattern); two new Lambda
  functions instead of one fewer

### Option D: Amazon Bedrock Flows

Use the native Bedrock Flows service to define the agent pipeline as a visual DAG,
eliminating both the Orchestrator Lambda and the Step Functions state machine.

- **Pros:** No custom orchestration code; native integration with Bedrock Agents;
  visual editor; built-in parallelism
- **Cons:** Bedrock Flows does not natively support Lambda Action Groups in the same
  agent pipeline with the same ease; less transparent for learning; limited control over
  inter-step data passing; the RepoScanner's Lambda-backed Action Group may require
  additional configuration; fewer observable failure modes

## Rationale

Option C is selected because:

1. **It fixes all observed production issues** — KMS grant problem is eliminated
   (SFN has no per-execution KMS grant), silent errors become visible Fail states,
   per-state CloudWatch logs replace single-stream grepping.

2. **Parallel execution is a structural correctness improvement** — the three middle
   agents are logically concurrent; running them sequentially was a code convenience,
   not an architectural requirement.

3. **AgentInvoker is a necessary adapter, not a violation of the principle** — the goal
   was to eliminate business logic from Lambda, not to eliminate Lambda entirely. The
   adapter is 35 lines and has one responsibility.

4. **The state machine is the single source of truth** for execution order, error
   handling, timeouts, and retries — these concerns are no longer scattered across Python
   code, try/except blocks, and env var-driven conditionals.

5. **Incremental rollback safety** — the old Orchestrator Lambda stays in place until
   Step 4 of the implementation plan, meaning the S3 trigger can be reverted in one
   `terraform apply` if any step fails.

## Consequences

- The `src/orchestrator/` directory and Lambda function are deleted after successful migration.
- Two new Lambda functions (`ParseS3Event`, `AgentInvoker`) replace the one Orchestrator.
- Two new IAM roles replace the `OrchestratorExecutionRole`.
- SFN Express Workflow costs are negligible at this volume (~$0.00001/state transition × 7 transitions per execution).
- The 256 KB SFN execution context limit must be monitored; see [state-machine.md payload overflow pattern](../refactor-sfn/state-machine.md#payload-overflow-pattern) for the mitigation.
- Adding a new README section in the future requires: one new Bedrock Agent module call in Terraform, one new parallel branch in the ASL, one new field in `AssembleCompilerInput`, and a prompt update to `Final_Compiler_Agent` — no Python code changes.
