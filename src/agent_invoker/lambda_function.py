import hashlib
import logging
import os
import time

import boto3

# ---------------------------------------------------------------------------
# OpenTelemetry — traces + logs.
# Both are no-ops if OTEL_EXPORTER_OTLP_ENDPOINT is not set.
# ---------------------------------------------------------------------------
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor
from opentelemetry.sdk.trace.export import SpanExporter, SpanExportResult
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor

_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()

if _endpoint:
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
    # Omit endpoint= so the SDK reads OTEL_EXPORTER_OTLP_ENDPOINT and auto-appends
    # /v1/traces and /v1/logs respectively.
    _processor = BatchSpanProcessor(OTLPSpanExporter())
    _log_provider = LoggerProvider()
    _log_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
else:
    # No collector configured — discard spans/logs silently.
    class _NoOpExporter(SpanExporter):
        def export(self, spans):
            return SpanExportResult.SUCCESS
        def shutdown(self):
            pass
    _processor = SimpleSpanProcessor(_NoOpExporter())
    _log_provider = LoggerProvider()

set_logger_provider(_log_provider)

# Bridge Python's stdlib logging → OTEL logs → Loki
from opentelemetry.sdk._logs._internal import OTLPHandler  # noqa: E402
_otel_handler = OTLPHandler(level=logging.DEBUG, logger_provider=_log_provider)
logging.getLogger().addHandler(_otel_handler)
logging.getLogger().setLevel(logging.DEBUG)
logger = logging.getLogger("readme-generator.agent-invoker")

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

    logger.info("agent.invoke.start", extra={
        "agent_id": agent_id,
        "alias_id": alias_id,
        "session_id": session_id,
        "function_name": context.function_name,
        "aws_request_id": context.aws_request_id,
    })

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
            logger.info("agent.invoke.complete", extra={
                "agent_id": agent_id,
                "session_id": session_id,
                "latency_ms": round(latency_ms),
                "response_length": len(result),
                "cost_estimated_usd": round(est_cost, 8),
            })
            result_payload = {"result": result}

        except Exception as exc:
            logger.error("agent.invoke.error", extra={
                "agent_id": agent_id,
                "session_id": session_id,
                "error": str(exc),
            })
            span.set_status(trace.StatusCode.ERROR, str(exc))
            span.record_exception(exc)
            _provider.force_flush(timeout_millis=5000)
            _log_provider.force_flush(timeout_millis=5000)
            raise

    _provider.force_flush(timeout_millis=5000)
    _log_provider.force_flush(timeout_millis=5000)
    return result_payload
