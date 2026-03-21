import hashlib
import os
import time

import boto3

# ---------------------------------------------------------------------------
# OpenTelemetry — no-op if OTEL_EXPORTER_OTLP_ENDPOINT is not set.
# Spans are created regardless; they are either exported or silently discarded.
# ---------------------------------------------------------------------------
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor
from opentelemetry.sdk.trace.export import SpanExporter, SpanExportResult

_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()

if _endpoint:
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    _processor = BatchSpanProcessor(OTLPSpanExporter(endpoint=_endpoint))
else:
    # No collector configured — discard spans silently.
    class _NoOpExporter(SpanExporter):
        def export(self, spans):
            return SpanExportResult.SUCCESS
        def shutdown(self):
            pass
    _processor = SimpleSpanProcessor(_NoOpExporter())

_provider = TracerProvider()
_provider.add_span_processor(_processor)
trace.set_tracer_provider(_provider)
_tracer = trace.get_tracer("readme-generator.agent-invoker")

# Approximate cost per character (Claude 3 on Bedrock, us-west-2).
# Bedrock InvokeAgent streaming does not expose token counts; use char length as proxy.
# TODO: replace with token-based cost when Bedrock adds token metadata to the response.
_COST_PER_CHAR = 0.000000003  # ~$0.003 per 1000 chars

client = boto3.client("bedrock-agent-runtime")


def handler(event, context):
    agent_id   = event["agent_id"]
    alias_id   = event["alias_id"]
    session_id = event["session_id"]
    input_text = event["input_text"]
    parent_trace_id = event.get("trace_context", {}).get("trace_id", "")

    with _tracer.start_as_current_span(
        "agent.invoke",
        attributes={
            "agent.id":          agent_id,
            "agent.alias_id":    alias_id,
            "agent.session_id":  session_id,
            "llm.prompt_hash":   hashlib.sha256(input_text.encode()).hexdigest(),
            "llm.prompt_length": len(input_text),
            "llm.provider":      "aws-bedrock",
            "llm.model":         "bedrock-agent",
            "sfn.trace_id":      parent_trace_id,
            "aws.lambda.name":   context.function_name,
            "aws.request_id":    context.aws_request_id,
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
            est_cost   = (len(input_text) + len(result)) * _COST_PER_CHAR

            span.set_attribute("llm.response_hash",        hashlib.sha256(result.encode()).hexdigest())
            span.set_attribute("llm.response_length",      len(result))
            span.set_attribute("llm.latency_ms",           round(latency_ms))
            span.set_attribute("llm.cost_estimated_usd",   round(est_cost, 8))
            # Inline eval signals — no second LLM call needed at this stage.
            span.set_attribute("llm.eval.output_nonempty",    len(result) > 50)
            span.set_attribute("llm.eval.output_is_markdown", result.strip().startswith("#"))
            span.set_status(trace.StatusCode.OK)
            return {"result": result}

        except Exception as exc:
            span.set_status(trace.StatusCode.ERROR, str(exc))
            span.record_exception(exc)
            raise
