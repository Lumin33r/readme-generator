# Architecture Diagrams — Step Functions Refactor

## System Context (After Refactor)

```mermaid
graph TD
    DEV["👤 Developer"]
    GHA["⚙️ GitHub Actions"]

    subgraph AWS["AWS (us-west-2)"]
        S3["S3 Bucket\n(inputs/ & outputs/)"]
        PARSE["ParseS3Event Lambda\n(bridge — 5s timeout)"]
        SFN["Step Functions\nExpress Workflow\nReadmeGeneratorPipeline"]
        INVOKER["AgentInvoker Lambda\n(shared streaming adapter)"]
        RS_AGENT["Repo_Scanner_Agent"]
        PS_AGENT["Project_Summarizer_Agent"]
        IG_AGENT["Installation_Guide_Agent"]
        UE_AGENT["Usage_Examples_Agent"]
        FC_AGENT["Final_Compiler_Agent"]
        RS_LAMBDA["RepoScannerTool Lambda\n(git clone)"]
        BEDROCK["Amazon Bedrock\n(Claude 3 Sonnet)"]
        CW["CloudWatch Logs\n+ SFN Execution History"]
    end

    GITHUB["GitHub\n(Public Repos)"]

    DEV -->|"aws s3 cp trigger"| S3
    GHA -->|"terraform apply / s3 cp"| S3
    S3 -->|"ObjectCreated event"| PARSE
    PARSE -->|"sfn:StartExecution"| SFN
    SFN -->|"Invoke(ScanRepo)"| INVOKER
    SFN -->|"Invoke(SummarizeProject)"| INVOKER
    SFN -->|"Invoke(WriteInstall)"| INVOKER
    SFN -->|"Invoke(WriteUsage)"| INVOKER
    SFN -->|"Invoke(CompileReadme)"| INVOKER
    SFN -->|"s3:PutObject (direct SDK)"| S3
    INVOKER -->|"InvokeAgent"| RS_AGENT
    INVOKER -->|"InvokeAgent"| PS_AGENT
    INVOKER -->|"InvokeAgent"| IG_AGENT
    INVOKER -->|"InvokeAgent"| UE_AGENT
    INVOKER -->|"InvokeAgent"| FC_AGENT
    RS_AGENT -->|"Action Group"| RS_LAMBDA
    RS_LAMBDA -->|"git clone --depth=1"| GITHUB
    RS_AGENT & PS_AGENT & IG_AGENT & UE_AGENT & FC_AGENT -->|"model invoke"| BEDROCK
    SFN -->|"execution logs"| CW
```

---

## State Machine Flow (Express Workflow)

```mermaid
stateDiagram-v2
    [*] --> ScanRepo

    ScanRepo: ScanRepo\nAgentInvoker → Repo_Scanner_Agent\ntimeout: 90s

    ScanRepo --> AnalyzeInParallel
    ScanRepo --> ScanFailed : on error (after 2 retries)

    state AnalyzeInParallel {
        [*] --> SummarizeProject
        [*] --> WriteInstallationGuide
        [*] --> WriteUsageExamples
        SummarizeProject --> [*]
        WriteInstallationGuide --> [*]
        WriteUsageExamples --> [*]
    }

    AnalyzeInParallel --> AssembleCompilerInput
    AnalyzeInParallel --> AnalysisFailed : on error

    AssembleCompilerInput: AssembleCompilerInput\nPass state — reshapes parallel results\nno Lambda, no cost

    AssembleCompilerInput --> CompileReadme

    CompileReadme: CompileReadme\nAgentInvoker → Final_Compiler_Agent\ntimeout: 60s

    CompileReadme --> UploadReadme
    CompileReadme --> CompileFailed : on error

    UploadReadme: UploadReadme\nDirect S3 SDK — s3:PutObject\ntimeout: 10s

    UploadReadme --> [*]

    ScanFailed --> [*]
    AnalysisFailed --> [*]
    CompileFailed --> [*]
```

---

## Data Flow Through the State Machine

```mermaid
sequenceDiagram
    participant S3
    participant ParseS3Event
    participant SFN as Step Functions
    participant Invoker as AgentInvoker Lambda
    participant Bedrock as Bedrock Agent Runtime
    participant S3out as S3 outputs/

    S3->>ParseS3Event: ObjectCreated (inputs/encoded-url)
    ParseS3Event->>SFN: StartExecution(input: {repo_url, repo_name, session_id, agents{}})

    SFN->>Invoker: Invoke {agent_id: RepoScanner, input_text: repo_url}
    Invoker->>Bedrock: InvokeAgent(RepoScanner)
    Bedrock-->>Invoker: EventStream → file_list string
    Invoker-->>SFN: {result: "...file list..."}
    Note over SFN: $.scan_result.file_list = "..."

    par Parallel fan-out (all start simultaneously)
        SFN->>Invoker: Invoke {agent_id: ProjectSummarizer, input_text: file_list}
        Invoker->>Bedrock: InvokeAgent(ProjectSummarizer)
        Bedrock-->>Invoker: EventStream → summary
        Invoker-->>SFN: {project_summary: "..."}
    and
        SFN->>Invoker: Invoke {agent_id: InstallationGuide, input_text: file_list}
        Invoker->>Bedrock: InvokeAgent(InstallationGuide)
        Bedrock-->>Invoker: EventStream → install section
        Invoker-->>SFN: {installation_guide: "..."}
    and
        SFN->>Invoker: Invoke {agent_id: UsageExamples, input_text: file_list}
        Invoker->>Bedrock: InvokeAgent(UsageExamples)
        Bedrock-->>Invoker: EventStream → usage section
        Invoker-->>SFN: {usage_examples: "..."}
    end

    Note over SFN: AssembleCompilerInput (Pass state — free reshape)

    SFN->>Invoker: Invoke {agent_id: FinalCompiler, input_text: JSON(name+summary+install+usage)}
    Invoker->>Bedrock: InvokeAgent(FinalCompiler)
    Bedrock-->>Invoker: EventStream → compiled README.md
    Invoker-->>SFN: {readme_content: "# RepoName\n..."}

    SFN->>S3out: PutObject(outputs/repo/README.md) — direct SDK
```

---

## Latency Comparison

```
Current (sequential):
  ScanRepo   ~50s  ████████████████████████████████████████████████████
  Summarize  ~25s                                          █████████████████████████
  Install    ~25s                                                                   █████████████████████████
  Usage      ~25s                                                                                          █████████████████████████
  Compile    ~25s                                                                                                                   █████████████████████████
  Total: ~150s  (close to 180s timeout)

After refactor (parallel fan-out):
  ScanRepo   ~50s  ████████████████████████████████████████████████████
  Parallel   ~25s                                          █████████████████████████
  (all 3 branches run at the same time)
  Compile    ~25s                                                                   █████████████████████████
  Total: ~100s  (50s saved, 44% faster)
```
