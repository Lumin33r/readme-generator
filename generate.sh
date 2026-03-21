#!/usr/bin/env bash
# generate.sh — trigger the README generator pipeline for a public GitHub repo.
#
# Usage:
#   ./generate.sh https://github.com/owner/repo
#   ./generate.sh          # prompts for URL interactively

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/infra"
OUTPUT_DIR="$SCRIPT_DIR/docs/outputs"
POLL_INTERVAL=10
TIMEOUT=300

# ---------------------------------------------------------------------------
# Resolve bucket name from Terraform output
# ---------------------------------------------------------------------------
echo "Resolving S3 bucket from Terraform output..."
BUCKET=$(terraform -chdir="$INFRA_DIR" output -raw readme_bucket_name 2>/dev/null)

if [[ -z "$BUCKET" ]]; then
  echo "Error: Could not retrieve bucket name. Run 'terraform apply' in infra/ first." >&2
  exit 1
fi
echo "Bucket: $BUCKET"

# ---------------------------------------------------------------------------
# Get repo URL
# ---------------------------------------------------------------------------
REPO_URL="${1:-}"
if [[ -z "$REPO_URL" ]]; then
  read -rp "Enter GitHub repo URL: " REPO_URL
fi

# Strip trailing slash and .git suffix
REPO_URL="${REPO_URL%/}"
REPO_URL="${REPO_URL%.git}"

if [[ ! "$REPO_URL" =~ ^https://github\.com/[^/]+/[^/]+$ ]]; then
  echo "Error: URL must be in the format https://github.com/owner/repo" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Encode URL to match the orchestrator's decoding logic:
#   https://github.com/owner/repo  ->  https---github.com-owner-repo
#
# Orchestrator decodes by:
#   1. replacing '---' with '://' (first occurrence)
#   2. replacing the first two '-' with '/' (owner separator, repo separator)
#
# So we encode:
#   '://' -> '---'
#   '/'   -> '-'
# ---------------------------------------------------------------------------
ENCODED=$(echo "$REPO_URL" | sed 's|://|---|' | tr '/' '-')
REPO_NAME=$(basename "$REPO_URL")

echo "Encoded trigger key : inputs/$ENCODED"
echo "Expecting output at : outputs/$REPO_NAME/README.md"
echo ""

# ---------------------------------------------------------------------------
# Delete any existing output so the poll doesn't return a stale result
# ---------------------------------------------------------------------------
OUTPUT_KEY="outputs/$REPO_NAME/README.md"
if aws s3api head-object --bucket "$BUCKET" --key "$OUTPUT_KEY" &>/dev/null; then
  echo "Removing previous output from S3..."
  aws s3 rm "s3://$BUCKET/$OUTPUT_KEY"
fi

# ---------------------------------------------------------------------------
# Upload empty trigger file to inputs/
# ---------------------------------------------------------------------------
TRIGGER_FILE=$(mktemp)
echo "Uploading trigger to s3://$BUCKET/inputs/$ENCODED ..."
aws s3 cp "$TRIGGER_FILE" "s3://$BUCKET/inputs/$ENCODED"
rm "$TRIGGER_FILE"
echo "Trigger uploaded. Pipeline is running..."
echo ""

# ---------------------------------------------------------------------------
# Poll S3 for the output README
# ---------------------------------------------------------------------------
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  if aws s3api head-object --bucket "$BUCKET" --key "$OUTPUT_KEY" &>/dev/null; then
    echo "Output ready! Downloading..."

    mkdir -p "$OUTPUT_DIR/$REPO_NAME"
    aws s3 cp "s3://$BUCKET/$OUTPUT_KEY" "$OUTPUT_DIR/$REPO_NAME/README.md"

    echo ""
    echo "Saved to: $OUTPUT_DIR/$REPO_NAME/README.md"
    echo "------------------------------------------------------------"
    cat "$OUTPUT_DIR/$REPO_NAME/README.md"
    exit 0
  fi

  echo "  Waiting for output... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# ---------------------------------------------------------------------------
# Timeout — print debugging hint
# ---------------------------------------------------------------------------
echo ""
echo "Timeout: README was not generated within ${TIMEOUT}s." >&2
echo ""
SFN_ARN=$(terraform -chdir="$INFRA_DIR" output -raw state_machine_arn 2>/dev/null || true)
echo "Debug with:"
echo "  # ParseS3Event Lambda (S3 trigger -> SFN bridge):"
echo "  aws logs tail /aws/lambda/ReadmeGeneratorParseS3Event --since 5m --region us-west-2"
echo "  # AgentInvoker Lambda (Bedrock streaming adapter):"
echo "  aws logs tail /aws/lambda/ReadmeGeneratorAgentInvoker --since 5m --region us-west-2"
if [[ -n "$SFN_ARN" ]]; then
  echo "  # Step Functions execution history:"
  echo "  aws stepfunctions list-executions --state-machine-arn $SFN_ARN --region us-west-2 --max-results 5"
fi
exit 1
