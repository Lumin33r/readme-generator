# OTEL Instrumentation Design — README Generator

> Instruments the `AgentInvoker` Lambda as the single observability injection point.
> Every Bedrock agent call passes through it — one span per invocation, one trace per SFN execution.

---

## Why AgentInvoker is the Right Injection Point

The Step Functions pipeline has a natural 1:1 mapping to OTEL primitives:

| SFN Concept                                           | OTEL Concept               |
| ----------------------------------------------------- | -------------------------- |
| Express Workflow execution                            | Root trace                 |
| Each `Task` state (`ScanRepo`, `CompileReadme`, etc.) | Child span                 |
| Each `branch` within `AnalyzeInParallel`              | Sibling span (same parent) |
| `AgentInvoker` Lambda body                            | Where spans are created    |

`AgentInvoker` is invoked once per agent, receives `agent_id`/`alias_id`/`session_id`/`input_text`,
and returns the streamed completion. It has everything needed to emit a complete `llm.call` span.

---

## Trace Hierarchy

```
sfn.execution  (trace_id = sfn execution name, propagated via SFN context object)
 ├── agent.invoke  [ScanRepo]        agent_id=NE0CSDQPDP
 ├── agent.invoke  [SummarizeProject] agent_id=PHM7GVBXKT  ─┐
 ├── agent.invoke  [InstallationGuide] agent_id=VXXWEHVIBC  ─┤ parallel, same parent
 ├── agent.invoke  [UsageExamples]   agent_id=2H19BVYH2V   ─┘
 └── agent.invoke  [FinalCompiler]   agent_id=ODTFJA4DKP
```

The SFN execution name (`{repo_name}-{aws_request_id}`) becomes the OTEL `trace_id` seed — it
is passed into each `AgentInvoker` payload as `trace_context.trace_id`.

---

## Instrumented `AgentInvoker` Lambda

```python
# src/agent_invoker/lambda_function.py
import hashlib
import json
import os
import time

import boto3
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# ---------------------------------------------------------------------------
# Bootstrap tracer once per Lambda cold start
# ---------------------------------------------------------------------------
_provider = TracerProvider()
_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
        )
    )
)
trace.set_tracer_provider(_provider)
tracer = trace.get_tracer("readme-generator.agent-invoker")

client = boto3.client("bedrock-agent-runtime")

# Approximate cost per token (us-west-2, Claude 3 Haiku on Bedrock, inference only)
# Update when model changes. This is an estimate — Bedrock does not return token counts
# in the InvokeAgent streaming response. Use character count as a proxy until AWS adds it.
_COST_PER_CHAR = 0.000000003  # ~$0.003 per 1000 chars, conservative


def handler(event, context):
    agent_id    = event["agent_id"]
    alias_id    = event["alias_id"]
    session_id  = event["session_id"]
    input_text  = event["input_text"]

    # Optional: caller can inject trace context for cross-service correlation
    parent_trace_id = event.get("trace_context", {}).get("trace_id")

    with tracer.start_as_current_span(
        "agent.invoke",
        attributes={
            # --- Identity ---
            "agent.id":           agent_id,
            "agent.alias_id":     alias_id,
            "agent.session_id":   session_id,
            # --- Input ---
            "llm.prompt_hash":    hashlib.sha256(input_text.encode()).hexdigest(),
            "llm.prompt_length":  len(input_text),
            "llm.provider":       "aws-bedrock",
            "llm.model":          "bedrock-agent",
            # --- Correlation ---
            "sfn.trace_id":       parent_trace_id or "",
            "aws.lambda.name":    context.function_name,
            "aws.request_id":     context.aws_request_id,
        },
    ) as span:
        t_start = time.monotonic()
        try:
            response = client.invoke_agent(
                agentId=agent_id,
                agentAliasId=alias_id,
                sessionId=session_id,
                inputText=input_text,
            )
            result = ""
            for chunk_event in response["completion"]:
                if "chunk" in chunk_event:
                    result += chunk_event["chunk"]["bytes"].decode()

            latency_ms = (time.monotonic() - t_start) * 1000

            # --- Output attributes (hashed for privacy) ---
            span.set_attribute("llm.response_hash",        hashlib.sha256(result.encode()).hexdigest())
            span.set_attribute("llm.response_length",      len(result))
            span.set_attribute("llm.latency_ms",           round(latency_ms))

            # --- Cost proxy (character-based until Bedrock exposes token counts) ---
            est_cost = (len(input_text) + len(result)) * _COST_PER_CHAR
            span.set_attribute("llm.cost_estimated_usd",   round(est_cost, 8))

            # --- Inline eval hook ---
            # Attach lightweight quality signals without a second LLM call.
            # Replace with a proper evaluator (see eval-strategy.md) once baseline is established.
            span.set_attribute("llm.eval.output_nonempty",    len(result) > 50)
            span.set_attribute("llm.eval.output_is_markdown", result.strip().startswith("#"))

            span.set_status(trace.StatusCode.OK)
            return {"result": result}

        except Exception as exc:
            span.set_status(trace.StatusCode.ERROR, str(exc))
            span.record_exception(exc)
            raise
```

---

## Span Attributes Reference

### Always present

| Attribute                | Value                                | Notes                                            |
| ------------------------ | ------------------------------------ | ------------------------------------------------ |
| `agent.id`               | e.g. `NE0CSDQPDP`                    | Bedrock agent resource ID                        |
| `agent.alias_id`         | `TSTALIASID`                         | Promotes to stable alias when promoted           |
| `agent.session_id`       | SFN `aws_request_id`                 | Groups all agents in one execution               |
| `llm.prompt_hash`        | SHA-256 of `input_text`              | Privacy-safe; enables prompt clustering          |
| `llm.prompt_length`      | `len(input_text)`                    | Char count (token proxy)                         |
| `llm.provider`           | `aws-bedrock`                        | Fixed                                            |
| `llm.response_hash`      | SHA-256 of response                  | Detect identical outputs across runs             |
| `llm.response_length`    | `len(result)`                        | Proxy for completion token count                 |
| `llm.latency_ms`         | Wall clock from invoke to last chunk | Includes Bedrock inference + streaming overhead  |
| `llm.cost_estimated_usd` | Character-based estimate             | Replace with token-based when Bedrock exposes it |
| `sfn.trace_id`           | SFN execution name                   | Cross-service correlation                        |

### Eval signals (inline, lightweight)

| Attribute                     | Type | What it catches                                          |
| ----------------------------- | ---- | -------------------------------------------------------- |
| `llm.eval.output_nonempty`    | bool | Agent returned nothing (empty response = silent failure) |
| `llm.eval.output_is_markdown` | bool | FinalCompiler produced valid markdown structure          |

> **Privacy rule (from llm-observability.md):** Never attach raw `input_text` or `result`
> to spans. Only hashes and lengths. Raw text stays inside CloudWatch Lambda logs
> (which are already scoped to the account and have controlled retention).

---

## Trace Context Propagation via SFN

SFN Express Workflows do not natively propagate W3C `traceparent` headers.
The approach: inject `trace_context` into the SFN input payload at `ParseS3Event` time,
so every downstream `AgentInvoker` invocation carries the same root trace ID.

**In `src/parse_s3_event/lambda_function.py`**, add to the `start_execution` input:

```python
from opentelemetry import trace as otel_trace

# Get current span context (ParseS3Event itself is a span)
ctx = otel_trace.get_current_span().get_span_context()
trace_context = {
    "trace_id": format(ctx.trace_id, "032x") if ctx.is_valid else context.aws_request_id,
    "span_id":  format(ctx.span_id, "016x")  if ctx.is_valid else "",
}

sfn.start_execution(
    stateMachineArn=STATE_MACHINE_ARN,
    name=f"{repo_name}-{context.aws_request_id}",
    input=json.dumps({
        ...existing fields...,
        "trace_context": trace_context,
    })
)
```

The `AgentInvoker` reads `event.get("trace_context", {})` and attaches it as `sfn.trace_id`.
This gives Tempo a stable key to group all 5 agent spans under one logical request.

---

## OTEL Collector Lambda Layer vs Sidecar

For AWS Lambda, two deployment patterns exist:

| Pattern                                 | Mechanism                                                                    | Best for                                           |
| --------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------- |
| **Lambda OTEL Extension** (recommended) | AWS-managed layer `arn:aws:lambda:us-west-2::layer:AWSOpenTelemetryDistro:*` | Simple setup, no VPC needed                        |
| **OTEL Collector ECS sidecar**          | Collector as ECS Fargate task                                                | If you need custom processors or batching at scale |

For this project (low volume, serverless), use the **AWS-managed Lambda layer**:

```hcl
# In infra/main.tf — add to aws_lambda_function.agent_invoker
layers = [
  "arn:aws:lambda:us-west-2::layer:AWSOpenTelemetryDistro:5"
]

environment {
  variables = {
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://${aws_lb.otel_collector_nlb.dns_name}:4317"
    OTEL_SERVICE_NAME           = "readme-generator-agent-invoker"
    OTEL_RESOURCE_ATTRIBUTES    = "deployment.environment=production"
    AWS_LAMBDA_EXEC_WRAPPER     = "/opt/otel-instrument"
  }
}
```

> The OTEL Collector NLB endpoint is an output of the `terraform-grafana-obs` module
> (see `terraform-module-plan.md`).

---

## RepoScannerTool Instrumentation (Optional / Phase 2)

The `RepoScannerTool` Lambda is a Bedrock action group — it executes synchronously inside
the `ScanRepo` agent invocation. Its CloudWatch logs are already linked to the agent session.
Add OTEL only if clone latency breakdowns are needed:

```python
with tracer.start_as_current_span("repo.clone") as span:
    span.set_attribute("repo.url_hash", hashlib.sha256(repo_url.encode()).hexdigest())
    span.set_attribute("git.clone.depth", 1)
    # result: span duration = clone time; error = clone failure reason
```
