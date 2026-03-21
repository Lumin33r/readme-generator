# API Design — AI README.md Generator

## Overview

This system has two API surfaces:

1. **OpenAPI Schema** — Defines the tool interface between the `Repo_Scanner_Agent` and the `RepoScannerTool` Lambda (Action Group contract).
2. **S3 Event Contract** — The implicit API between S3 and the Orchestrator Lambda (event-driven, no REST endpoints).

There are no user-facing HTTP APIs. All interaction is through S3 file uploads.

---

## 1. Repo Scanner OpenAPI Schema

Defined in `repo_scanner_schema.json`. This file is consumed by the Bedrock Agent Action Group to understand when and how to invoke the Lambda tool.

### Endpoint: `POST /scan-repo`

**Request:**

```json
{
  "repo_url": "https://github.com/User/Repo"
}
```

| Field      | Type   | Required | Description                            |
| ---------- | ------ | -------- | -------------------------------------- |
| `repo_url` | string | Yes      | Full URL of a public GitHub repository |

**Response (200):**

```json
{
  "files": ["main.py", "requirements.txt", "src/app.py", "README.md"]
}
```

| Field   | Type          | Description                                           |
| ------- | ------------- | ----------------------------------------------------- |
| `files` | array[string] | Relative file paths from repo root (`.git/` excluded) |

**Error behavior:** Returns `{"files": []}` on failure (clone error, invalid URL). Does not return HTTP error codes — the agent sees an empty list and proceeds accordingly.

---

## 2. S3 Event Contract (Trigger Interface)

### Input: Trigger File Upload

| Property           | Value                                                |
| ------------------ | ---------------------------------------------------- |
| Bucket             | `readme-generator-output-bucket-<random>`            |
| Key prefix         | `inputs/`                                            |
| File content       | Empty (0 bytes)                                      |
| File name encoding | URL → filename: `://` becomes `---`, `/` becomes `-` |

**Encoding example:**

```
URL:      https://github.com/TruLie13/municipal-ai
Filename: inputs/https---github.com-TruLie13-municipal-ai
```

**Decoding logic (in Orchestrator):**

1. Strip `inputs/` prefix
2. Replace first `---` with `://`
3. Replace the next two `-` with `/` (domain separator + org/repo separator)

### Output: Generated README

| Property     | Value                                 |
| ------------ | ------------------------------------- |
| Bucket       | Same bucket (`OUTPUT_BUCKET` env var) |
| Key          | `outputs/<repo-name>/README.md`       |
| Content-Type | `text/markdown`                       |

---

## 3. Agent Invocation Interface (boto3)

The Orchestrator calls each agent using `bedrock-agent-runtime:InvokeAgent`.

```python
response = bedrock_agent_runtime_client.invoke_agent(
    agentId=agent_id,
    agentAliasId=alias_id,
    sessionId=session_id,    # unique per invocation (context.aws_request_id)
    inputText=input_text     # string — file list JSON or assembled sections JSON
)
```

**Response format:** Streaming — the client iterates `response["completion"]` events and concatenates `chunk["bytes"]` to assemble the full text response.

### Inter-Agent Data Flow

```
Orchestrator
  │
  ├─▶ Repo_Scanner_Agent(repo_url) ──▶ file_list_json
  │
  ├─▶ Project_Summarizer_Agent(file_list_json) ──▶ project_summary (text)
  ├─▶ Installation_Guide_Agent(file_list_json) ──▶ installation_guide (markdown)
  ├─▶ Usage_Examples_Agent(file_list_json) ──▶ usage_examples (markdown)
  │
  └─▶ Final_Compiler_Agent(compiler_input_json) ──▶ final_readme (markdown)
```

**compiler_input_json structure:**

````json
{
  "repository_name": "municipal-ai",
  "project_summary": "This is a Python project...",
  "installation_guide": "## Installation\n```bash\npip install...",
  "usage_examples": "## Usage\n```bash\npython main.py..."
}
````
