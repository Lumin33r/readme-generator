# Data Architecture — AI README.md Generator

## Data Stores

This system uses **Amazon S3** as its sole data store. There is no database for application data — all state is transient (Lambda execution context) or stored as files in S3.

### S3 Bucket: `readme-generator-output-bucket-<random>`

| Prefix            | Purpose                                      | Written By                           | Read By                        |
| ----------------- | -------------------------------------------- | ------------------------------------ | ------------------------------ |
| `inputs/`         | Trigger files (empty, filename-encoded URLs) | Developer (manual) or GitHub Actions | Orchestrator Lambda (S3 event) |
| `outputs/<repo>/` | Generated README.md files                    | Orchestrator Lambda                  | Developer (download)           |

**Lifecycle:** Trigger files in `inputs/` are never cleaned up automatically. Generated READMEs in `outputs/` are overwritten on each run for the same repo name.

### S3 Bucket: `tf-readme-generator-state-<random>`

| Key                           | Purpose                     |
| ----------------------------- | --------------------------- |
| `global/s3/terraform.tfstate` | Terraform remote state file |

Used exclusively by Terraform CLI (local or in GitHub Actions). Never accessed by application code.

### DynamoDB Table: `readme-generator-tf-locks`

| Attribute | Type              | Purpose                                    |
| --------- | ----------------- | ------------------------------------------ |
| `LockID`  | String (hash key) | Prevents concurrent `terraform apply` runs |

Billing mode: PAY_PER_REQUEST (no provisioned capacity needed).

---

## Data Flow

### Input Encoding

GitHub URLs are encoded into filenames because S3 object keys cannot contain `://` reliably across all tools. The encoding scheme:

```
https://github.com/TruLie13/municipal-ai
  ↓ encode
https---github.com-TruLie13-municipal-ai
  ↓ S3 key
inputs/https---github.com-TruLie13-municipal-ai
```

### Processing Pipeline Data

All intermediate data lives **in-memory** within the Orchestrator Lambda execution:

1. **S3 event** → extract bucket + key → decode to `repo_url`
2. `repo_url` → Repo Scanner Agent → `file_list_json` (string, held in memory)
3. `file_list_json` → 3 analytical agents → `project_summary`, `installation_guide`, `usage_examples` (strings)
4. Sections assembled into `compiler_input_json` → Final Compiler Agent → `readme_content` (string)
5. `readme_content` → S3 PutObject

**No intermediate data is persisted.** If the Lambda fails mid-execution, the entire chain must be re-run.

### Output Format

The final artifact is a standard Markdown file:

````markdown
# <repository-name>

## Project Summary

<factual summary paragraph>

## Installation

```bash
<install command>
```
````

## Usage

```bash
<run command>
```

```

---

## Temporary Storage

The `RepoScannerTool` Lambda clones repositories to `/tmp/repo` (Lambda ephemeral storage, 512 MB default). The directory is cleaned up (`shutil.rmtree`) before each clone. This data never leaves the Lambda execution environment.
```
