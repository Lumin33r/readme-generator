# ADR-0001: Serverless Multi-Agent Architecture

## Status

Accepted

## Context

We need to build a system that takes a public GitHub repository URL and generates a professional README.md file. The system must use AWS services, Terraform for IaC, and Amazon Bedrock for AI capabilities.

Key constraints:

- Must run on AWS (Bedrock, Lambda, S3)
- Must be fully automated via Terraform
- Must support CI/CD via GitHub Actions
- Must demonstrate multi-agent collaboration patterns
- No persistent compute (serverless preferred)

## Options Considered

### Option A: Single Monolithic Lambda + Single Bedrock Invoke

One Lambda function that clones the repo, builds a large prompt with all instructions, calls Bedrock once, and writes the result to S3.

- **Pros:** Simplest architecture, fewest resources, lowest latency
- **Cons:** Single massive prompt is harder to tune; no separation of concerns; all-or-nothing output quality; doesn't teach agent patterns

### Option B: Multi-Agent Pipeline with Orchestrator (Selected)

Five specialized Bedrock Agents, each with a single responsibility, coordinated by an Orchestrator Lambda. One agent has a Lambda-backed Action Group for external interaction (git clone).

- **Pros:** Each agent's prompt is focused and tunable independently; demonstrates real-world multi-agent patterns; modular (can add/remove agents); teaches Action Groups, prompt engineering, and orchestration
- **Cons:** Higher latency (sequential invocations); more IAM roles and resources; debugging requires tracing across multiple agents

### Option C: Bedrock Flows (Native Orchestration)

Use Amazon Bedrock Flows to define the agent pipeline as a visual DAG instead of custom orchestrator code.

- **Pros:** No custom orchestration code; visual pipeline editor; built-in retry/error handling
- **Cons:** Less transparent (harder to debug); limited control over inter-step data passing; fewer learning opportunities around Lambda orchestration

## Decision

**Option B** — A multi-agent pipeline with a custom Orchestrator Lambda.

## Rationale

1. **Educational value:** The sequential orchestration pattern teaches fundamental distributed systems skills (event handling, inter-service data passing, error propagation).

2. **Prompt isolation:** Each agent has a single, focused prompt that can be independently tested and refined (Lab 5 demonstrates this with one-shot prompting improvements).

3. **Modularity:** Adding a new section to the README means adding one new agent module call — the orchestrator and compiler adapt automatically.

4. **Action Group pattern:** The Repo Scanner Agent demonstrates the critical Bedrock capability of giving agents external tools via Lambda-backed Action Groups.

5. **Event-driven trigger:** S3 notifications provide a clean, decoupled input mechanism that works for both manual triggers and CI/CD automation.

## Consequences

- The Orchestrator Lambda's 180-second timeout must accommodate 5 sequential agent invocations (~20-40 seconds each).
- All inter-agent data flows through the Orchestrator's memory — if it fails mid-chain, the entire run must be retried.
- The `TSTALIASID` test alias is used for all agents (no versioned aliases), which means agent changes take effect immediately without a deployment step.
- The system is inherently sequential — the Summarizer, Install Guide, and Usage agents could theoretically run in parallel, but the current design keeps them sequential for simplicity.
