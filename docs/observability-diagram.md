# Observability Architecture Diagrams — README Generator

---

## 1. Telemetry Context Diagram

Who emits what, and where it lands.

```mermaid
graph TB
    subgraph AWS["AWS us-west-2"]
        S3[("S3\nreadme-generator-output-bucket")]
        ParseLambda["ParseS3Event Lambda\n(bridge)"]
        SFN["Step Functions\nReadmeGeneratorPipeline\n[EXPRESS]"]
        AgentInvoker["AgentInvoker Lambda\n(×5 calls / execution)"]
        RepoScanner["RepoScannerTool Lambda\n(Bedrock action group)"]
        CW[("CloudWatch\nLogs + Metrics")]
        CWSFN["/aws/states/ReadmeGeneratorPipeline"]
        CWParse["/aws/lambda/ReadmeGeneratorParseS3Event"]
        CWAgent["/aws/lambda/ReadmeGeneratorAgentInvoker"]
        CWRepo["/aws/lambda/RepoScannerTool"]
    end

    subgraph OBS["Observability Stack (ECS Fargate)"]
        OTEL["OTEL Collector\ngateway"]
        Tempo[("Tempo\ntrace store")]
        Loki[("Loki\nlog store")]
        Prom[("Prometheus\nmetrics TSDB")]
        Grafana["Grafana\ndashboards + alerts"]
    end

    subgraph CICD["CI/CD (GitHub Actions)"]
        Tests["pytest eval suite\ngolden dataset + trajectory"]
        HashStore[("S3\neval-baseline/")]
    end

    S3 -->|"s3:ObjectCreated inputs/"| ParseLambda
    ParseLambda -->|"StartExecution"| SFN
    SFN -->|"Invoke (×5)"| AgentInvoker
    AgentInvoker -->|"InvokeAgent"| RepoScanner

    ParseLambda -->|"structured logs"| CWParse
    AgentInvoker -->|"structured logs"| CWAgent
    RepoScanner -->|"structured logs"| CWRepo
    SFN -->|"execution events"| CWSFN

    AgentInvoker -->|"OTEL spans\n(gRPC :4317)"| OTEL
    OTEL -->|"traces"| Tempo
    OTEL -->|"span→metric"| Prom
    CW -->|"CW Logs exporter"| Loki
    CW -->|"CW Metrics exporter"| Prom

    Tempo --> Grafana
    Loki --> Grafana
    Prom --> Grafana

    Tests -->|"trigger + validate"| S3
    Tests -->|"response hash"| HashStore
```

---

## 2. Trace Hierarchy (One SFN Execution)

How spans nest inside a single `./generate.sh` run.

```mermaid
gantt
    title Trace Timeline — Single README Generation
    dateFormat  ss.SSS
    axisFormat  %S.%Ls

    section ParseS3Event
    parse.s3_event (10ms)        : 0.000, 0.010

    section ScanRepo
    agent.invoke NE0CSDQPDP      : 0.010, 15.000

    section AnalyzeInParallel (concurrent)
    agent.invoke PHM7GVBXKT      : 15.000, 35.000
    agent.invoke VXXWEHVIBC      : 15.000, 33.000
    agent.invoke 2H19BVYH2V      : 15.000, 37.000

    section CompileReadme
    agent.invoke ODTFJA4DKP      : 37.000, 55.000

    section UploadReadme
    s3.putObject                 : 55.000, 55.500
```

**Span parent–child relationship** (Tempo TraceQL query):

```
{ span.sfn.trace_id = "<execution-name>" } | select(span.agent.id, span.llm.latency_ms, span.llm.cost_estimated_usd)
```

---

## 3. Sequence Diagram — CI/CD Eval Flow

```mermaid
sequenceDiagram
    participant GHA as GitHub Actions
    participant S3 as S3 Bucket
    participant SFN as Step Functions
    participant AInv as AgentInvoker
    participant Tempo as Tempo
    participant Prom as Prometheus

    GHA->>S3: Upload trigger (inputs/https---github.com-...)
    S3-->>SFN: S3 event → ParseS3Event → StartExecution
    loop 5 agents
        SFN->>AInv: Lambda Invoke (agent_id, input_text, trace_context)
        AInv->>Tempo: OTEL span (agent.invoke, llm.* attrs)
        AInv->>Prom: span→metric (latency, cost)
        AInv-->>SFN: { result: "..." }
    end
    SFN->>S3: PutObject outputs/README.md
    GHA->>S3: Poll for outputs/ (300s timeout)
    GHA->>GHA: Validate sections (expected_sections.json)
    GHA->>GHA: Compare response_hash vs baseline
    GHA->>S3: Write new baseline hash (eval-baseline/)
```

---

## 4. Grafana Dashboard Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  README Generator — Pipeline Overview                            │
├──────────────┬──────────────┬──────────────┬────────────────────┤
│ Executions/h │ Avg duration │ Error rate   │ Est. cost/run      │
│   [number]   │   [seconds]  │   [percent]  │   [USD]            │
├──────────────┴──────────────┴──────────────┴────────────────────┤
│  Agent Latency (p50 / p95 / p99) — line chart per agent_id      │
├─────────────────────────────────────────────────────────────────┤
│  Live Traces — Tempo panel (last 20 executions, trace explorer)  │
├─────────────────────────────────────────────────────────────────┤
│  Eval Signals                                                    │
│  output_nonempty rate  │  output_is_markdown rate  │  hash drift │
├─────────────────────────────────────────────────────────────────┤
│  CloudWatch Lambda Metrics (errors, throttles, duration)        │
│  ParseS3Event  │  AgentInvoker  │  RepoScannerTool              │
├─────────────────────────────────────────────────────────────────┤
│  Loki — log explorer (filter: agent_id, session_id, error)      │
└─────────────────────────────────────────────────────────────────┘
```
