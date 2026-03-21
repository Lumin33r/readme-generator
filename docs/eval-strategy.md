# Eval Strategy — README Generator

> Two complementary layers: **CI/CD deterministic evals** (run before deploy) and
> **live telemetry quality signals** (captured in production traces). Neither replaces the other.

---

## Eval Layer Map (from llm-eval.md, applied to this system)

| Layer                                          | CI/CD                          | Live Trace                                   | Owner         |
| ---------------------------------------------- | ------------------------------ | -------------------------------------------- | ------------- |
| Task outcome (README produced?)                | ✓ golden dataset               | ✓ `llm.eval.output_nonempty` span attr       | Both          |
| Answer quality (markdown structure)            | ✓ section presence check       | ✓ `llm.eval.output_is_markdown` span attr    | Both          |
| Per-agent trajectory (correct order, no loops) | ✓ SFN execution history replay | ✓ SFN state machine CloudWatch events        | CI/CD primary |
| Tool use (RepoScanner action group fires)      | ✓ mock invocation test         | ✓ CW action group invocation log             | CI/CD primary |
| Latency / cost                                 | —                              | ✓ `llm.latency_ms`, `llm.cost_estimated_usd` | Live primary  |
| Hallucination / groundedness                   | Phase 2 evaluator LLM          | Phase 2 async eval span                      | Future        |
| Regression (output drift across deploys)       | ✓ hash comparison              | ✓ `llm.response_hash` drift alert            | Both          |

---

## CI/CD Eval Pipeline

### When it runs

Every PR merge into `main` and every `terraform apply` in the GitHub Actions workflow.

### What it tests

#### 1. Golden Dataset — Task Outcome

A set of 3–5 known-good public repos with expected README sections stored in `tests/golden/`.

```
tests/
  golden/
    modelcontextprotocol/
      expected_sections.json      # ["Installation", "Usage", "Features"]
    fastapi/
      expected_sections.json
    hello-world/
      expected_sections.json
  eval/
    test_readme_sections.py       # pytest suite
    test_agent_trajectory.py      # SFN history replay
    conftest.py                   # boto3 fixtures
```

**`tests/golden/*/expected_sections.json`** specifies minimum required H2 headings:

```json
{
  "required_sections": ["Installation", "Usage"],
  "forbidden_phrases": ["I am an AI", "I cannot"],
  "min_length_chars": 500
}
```

**`tests/eval/test_readme_sections.py`**:

```python
import json
import re
import boto3
import pytest

BUCKET = "readme-generator-output-bucket-mg481ly5"
GOLDEN = "tests/golden"

@pytest.mark.parametrize("repo_slug", ["modelcontextprotocol", "fastapi"])
def test_readme_has_required_sections(repo_slug, trigger_pipeline):
    """
    trigger_pipeline is a conftest fixture that uploads the trigger key to S3
    and polls for the output with a 300s timeout — same logic as generate.sh.
    """
    readme = trigger_pipeline(repo_slug)
    spec = json.load(open(f"{GOLDEN}/{repo_slug}/expected_sections.json"))

    headings = re.findall(r"^#{1,3} (.+)$", readme, re.MULTILINE)
    for section in spec["required_sections"]:
        assert any(section.lower() in h.lower() for h in headings), \
            f"Missing section '{section}' in {repo_slug} README"

    for phrase in spec.get("forbidden_phrases", []):
        assert phrase not in readme, f"Forbidden phrase found: '{phrase}'"

    assert len(readme) >= spec.get("min_length_chars", 200), "README too short"
```

#### 2. Agent Trajectory — SFN Execution History

```python
# tests/eval/test_agent_trajectory.py
import boto3

sfn = boto3.client("stepfunctions", region_name="us-west-2")
EXPECTED_STATES = [
    "ScanRepo",
    "AnalyzeInParallel",
    "AssembleCompilerInput",
    "CompileReadme",
    "UploadReadme",
]

def test_execution_visits_all_states(last_execution_arn):
    history = sfn.get_execution_history(executionArn=last_execution_arn, maxResults=100)
    entered = [
        e["stateEnteredEventDetails"]["name"]
        for e in history["events"]
        if e["type"] == "TaskStateEntered"
    ]
    for state in EXPECTED_STATES:
        assert state in entered, f"State '{state}' was never entered"

def test_no_failed_states(last_execution_arn):
    history = sfn.get_execution_history(executionArn=last_execution_arn, maxResults=100)
    failed = [e for e in history["events"] if "Failed" in e["type"]]
    assert len(failed) == 0, f"Failed states found: {[e['type'] for e in failed]}"
```

#### 3. Response Hash Regression (CI/CD)

On each CI run, store `llm.response_hash` per agent to S3 and compare against the previous run.
A hash change is not a failure — it is a **signal** that triggers human review.

```bash
# In GitHub Actions workflow (post-generate step):
HASHES=$(aws xray get-trace-summaries ... | jq '[.TraceSummaries[].Annotations."llm.response_hash"]')
aws s3 cp - "s3://$BUCKET/eval-baseline/latest-hashes.json" <<< "$HASHES"
# Compare: diff previous vs current, post to PR comment if changed
```

---

## Live Telemetry Quality Signals

Captured as OTEL span attributes on every production run — no separate eval Lambda needed
for the initial release. See [otel-instrumentation.md](otel-instrumentation.md) for the
full attribute list. The critical live eval attributes:

| Attribute                     | Alert condition               | Grafana panel                       |
| ----------------------------- | ----------------------------- | ----------------------------------- |
| `llm.eval.output_nonempty`    | `false` on any agent span     | "Silent agent failure" alert        |
| `llm.eval.output_is_markdown` | `false` on FinalCompiler span | "README format regression" alert    |
| `llm.latency_ms`              | p95 > 45,000ms                | "Agent latency SLO" panel           |
| `llm.cost_estimated_usd`      | sum > $0.10 per execution     | "Cost per run" panel                |
| `llm.response_length`         | < 100 chars                   | "Suspiciously short response" alert |

### Prometheus recording rules for the above

```yaml
# In OTEL Collector → Prometheus pipeline
# These attributes are exported as Prometheus metrics via the OTEL span-to-metric connector
groups:
  - name: readme_generator_llm
    rules:
      - record: readme_generator:agent_latency_p95
        expr: histogram_quantile(0.95, rate(agent_invoke_latency_ms_bucket[5m]))
      - alert: AgentSilentFailure
        expr: agent_invoke_output_nonempty == 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Agent {{ $labels.agent_id }} returned empty output"
      - alert: ReadmeFormatRegression
        expr: agent_invoke_output_is_markdown{agent_id="ODTFJA4DKP"} == 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "FinalCompiler produced non-markdown output"
```

---

## Phase 2: Async Evaluator Lambda (Future)

After the `FinalCompiler` uploads the README, an S3 `outputs/` event triggers a lightweight
evaluator Lambda that runs a second Bedrock call to score the README against the source repo.

```
S3 PutObject (outputs/)
  → EvaluatorLambda
    → invoke_agent(evaluator_agent, input={"readme": ..., "repo_url": ...})
    → emit OTEL span as child of original trace_id
      - llm.eval.relevance_score  (0.0–1.0)
      - llm.eval.hallucination_detected (bool)
      - llm.eval.sections_present (list)
    → PutMetricData to CloudWatch custom namespace "ReadmeGenerator/Eval"
```

This adds a second LLM call per run (~$0.001) but gives a continuous quality signal
that CI/CD evals cannot provide (CI runs on synthetic repos, not user-submitted ones).

---

## CI/CD vs Live — Decision Matrix

| Question                                  | Where to answer it       |
| ----------------------------------------- | ------------------------ |
| "Does the system produce a valid README?" | CI/CD golden dataset     |
| "Did the SFN take the right path?"        | CI/CD trajectory test    |
| "How fast was agent X on this repo?"      | Live trace (Tempo)       |
| "Is cost per run trending up?"            | Live metric (Prometheus) |
| "Did any agent silently fail?"            | Live alert (Grafana)     |
| "Is quality degrading across deploys?"    | Hash regression (both)   |
| "Is the README factually grounded?"       | Phase 2 async eval       |
