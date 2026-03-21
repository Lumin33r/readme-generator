# Backend — AI README.md Generator

## Lambda Functions

### 1. RepoScannerTool (`src/repo_scanner/lambda_function.py`)

| Property | Value                                             |
| -------- | ------------------------------------------------- |
| Runtime  | Python 3.11                                       |
| Timeout  | 30 seconds                                        |
| IAM Role | `ReadmeGeneratorLambdaExecutionRole`              |
| Layer    | `git-lambda2:8` (provides `/usr/bin/git`)         |
| Trigger  | Bedrock Agent Action Group (not directly invoked) |

**Responsibility:** Clones a public GitHub repository to `/tmp/repo`, walks the file tree (excluding `.git/`), and returns a flat list of relative file paths.

**Input:** Bedrock Agent event with `repo_url` in `requestBody.content.application/json.properties`.

**Output:** Bedrock-formatted response wrapping `{"files": ["file1.py", "file2.txt", ...]}`.

**Error handling:** Returns `{"files": []}` on clone failure or missing URL — the agent chain continues with an empty file list rather than crashing.

---

### 2. Orchestrator (`src/orchestrator/lambda_function.py`)

| Property | Value                                                            |
| -------- | ---------------------------------------------------------------- |
| Runtime  | Python 3.11                                                      |
| Timeout  | 180 seconds                                                      |
| IAM Role | `ReadmeGeneratorOrchestratorExecutionRole`                       |
| Trigger  | S3 event notification (`s3:ObjectCreated:*` on `inputs/` prefix) |

**Responsibility:** The "project manager" — decodes the repo URL from the S3 event, sequentially invokes all 5 Bedrock agents, and writes the final README.md to S3.

**Environment variables (set by Terraform):**

| Variable                            | Source                                     |
| ----------------------------------- | ------------------------------------------ |
| `REPO_SCANNER_AGENT_ID`             | `module.repo_scanner_agent.agent_id`       |
| `REPO_SCANNER_AGENT_ALIAS_ID`       | `TSTALIASID` (test alias)                  |
| `PROJECT_SUMMARIZER_AGENT_ID`       | `module.project_summarizer_agent.agent_id` |
| `PROJECT_SUMMARIZER_AGENT_ALIAS_ID` | `TSTALIASID`                               |
| `INSTALLATION_GUIDE_AGENT_ID`       | `module.installation_guide_agent.agent_id` |
| `INSTALLATION_GUIDE_AGENT_ALIAS_ID` | `TSTALIASID`                               |
| `USAGE_EXAMPLES_AGENT_ID`           | `module.usage_examples_agent.agent_id`     |
| `USAGE_EXAMPLES_AGENT_ALIAS_ID`     | `TSTALIASID`                               |
| `FINAL_COMPILER_AGENT_ID`           | `module.final_compiler_agent.agent_id`     |
| `FINAL_COMPILER_AGENT_ALIAS_ID`     | `TSTALIASID`                               |
| `OUTPUT_BUCKET`                     | `module.s3_bucket.bucket_id`               |

**Invocation order:**

1. `Repo_Scanner_Agent` → returns file list JSON
2. `Project_Summarizer_Agent` → receives file list → returns summary paragraph
3. `Installation_Guide_Agent` → receives file list → returns install section
4. `Usage_Examples_Agent` → receives file list → returns usage section
5. `Final_Compiler_Agent` → receives assembled JSON of all sections → returns compiled README.md

---

## Bedrock Agents

All agents use **Claude 3 Sonnet** (`anthropic.claude-3-sonnet-20240229-v1:0`) and share the `ReadmeGeneratorBedrockAgentRole`.

### Agent 1: Repo_Scanner_Agent

| Property         | Value                                                       |
| ---------------- | ----------------------------------------------------------- |
| Has Action Group | Yes — linked to `RepoScannerTool` Lambda via OpenAPI schema |
| Input            | GitHub repository URL                                       |
| Output           | JSON file list                                              |

**Unique characteristic:** The only agent with an Action Group. Uses the OpenAPI schema (`repo_scanner_schema.json`) to describe its `/scan-repo` tool so the model knows when and how to call the Lambda.

### Agent 2: Project_Summarizer_Agent

| Property         | Value                                          |
| ---------------- | ---------------------------------------------- |
| Has Action Group | No (prompt-only)                               |
| Input            | File list JSON                                 |
| Output           | Single summary paragraph (no hedging language) |

**Prompt strategy:** Instructs the model to state analysis as fact — no "appears to be" or "likely" language. Infers language, frameworks, and purpose from filenames and extensions.

### Agent 3: Installation_Guide_Agent

| Property         | Value                                          |
| ---------------- | ---------------------------------------------- |
| Has Action Group | No (prompt-only)                               |
| Input            | File list JSON                                 |
| Output           | `## Installation` section with bash code block |

**Prompt strategy:** One-shot prompting — provides an exact example of the desired output format (`pip install -r requirements.txt` in a code block). Returns empty string if no dependency file is found.

### Agent 4: Usage_Examples_Agent

| Property         | Value                                   |
| ---------------- | --------------------------------------- |
| Has Action Group | No (prompt-only)                        |
| Input            | File list JSON                          |
| Output           | `## Usage` section with bash code block |

**Prompt strategy:** One-shot prompting — shows the exact format expected. Identifies entry points like `main.py`, `index.js`, `app.py`.

### Agent 5: Final_Compiler_Agent

| Property         | Value                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------- |
| Has Action Group | No (prompt-only)                                                                              |
| Input            | JSON object with `repository_name`, `project_summary`, `installation_guide`, `usage_examples` |
| Output           | Complete, formatted Markdown document                                                         |

**Prompt strategy:** Strict anti-filler constraints — explicitly told "Do NOT include any preamble, apologies, explanations of your process, or any conversational text." Assembles sections under proper H1/H2 headers.
