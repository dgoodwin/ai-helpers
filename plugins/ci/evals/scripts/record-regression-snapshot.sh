#!/bin/bash
# Record HTTP responses for an analyze-regression eval case.
#
# Runs each data-fetching script with EVAL_SNAPSHOT_RECORD=1 to capture
# all HTTP responses to the snapshot directory. The responses are replayed
# during eval runs so tests work against frozen, deterministic data.
#
# Usage:
#   ./plugins/ci/evals/scripts/record-regression-snapshot.sh <regression_id> [case_dir]
#
# Examples:
#   ./plugins/ci/evals/scripts/record-regression-snapshot.sh 34446
#   ./plugins/ci/evals/scripts/record-regression-snapshot.sh 34446 plugins/ci/evals/cases/analyze-regression/case-001-permafail

set -euo pipefail

REGRESSION_ID="${1:?Usage: $0 <regression_id> [case_dir]}"
CASE_DIR="${2:-plugins/ci/evals/cases/analyze-regression/case-${REGRESSION_ID}}"

export EVAL_SNAPSHOT_DIR="$CASE_DIR/snapshot"
export EVAL_SNAPSHOT_RECORD=1

mkdir -p "$EVAL_SNAPSHOT_DIR/http_responses"

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CI_SKILLS="$REPO_ROOT/plugins/ci/skills"
TEAMS_SKILLS="$REPO_ROOT/plugins/teams/skills"

echo "Recording snapshot for regression $REGRESSION_ID" >&2
echo "Case dir: $CASE_DIR" >&2
echo "Snapshot dir: $EVAL_SNAPSHOT_DIR" >&2
echo "" >&2

# Step 1: Fetch regression details
echo "[1/8] Fetching regression details..." >&2
REGRESSION_DATA=$(python3 "$CI_SKILLS/fetch-regression-details/fetch_regression_details.py" \
    "$REGRESSION_ID" --format json 2>/dev/null)

if [ -z "$REGRESSION_DATA" ]; then
    echo "ERROR: Failed to fetch regression $REGRESSION_ID" >&2
    exit 1
fi

# Extract fields for subsequent calls
TEST_NAME=$(echo "$REGRESSION_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test_name',''))")
TEST_ID=$(echo "$REGRESSION_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test_id',''))")
RELEASE=$(echo "$REGRESSION_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('release',''))")

echo "  Test: $TEST_NAME" >&2
echo "  Release: $RELEASE" >&2

# Step 2: Fetch test report
echo "[2/8] Fetching test report..." >&2
python3 "$CI_SKILLS/fetch-test-report/fetch_test_report.py" \
    "$TEST_NAME" --release "$RELEASE" --no-collapse --format json \
    2>/dev/null > /dev/null || echo "  Warning: test report fetch failed" >&2

# Step 3: Fetch test runs (failed job run outputs)
echo "[3/8] Fetching test runs..." >&2
JOB_RUN_IDS=$(echo "$REGRESSION_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ids = []
for job_data in d.get('sample_failed_jobs', {}).values():
    for run in job_data.get('failed_runs', []):
        rid = run.get('job_run_id', '')
        if rid:
            ids.append(rid)
print(','.join(ids[:20]))
")
if [ -n "$JOB_RUN_IDS" ] && [ -n "$TEST_ID" ]; then
    python3 "$CI_SKILLS/fetch-test-runs/fetch_test_runs.py" \
        "$TEST_ID" "$JOB_RUN_IDS" --format json \
        2>/dev/null > /dev/null || echo "  Warning: test runs fetch failed" >&2
fi

# Step 4: Fetch job run summaries (up to 3 representative runs)
echo "[4/8] Fetching job run summaries..." >&2
SAMPLE_RUN_IDS=$(echo "$REGRESSION_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ids = []
for job_data in d.get('sample_failed_jobs', {}).values():
    runs = job_data.get('failed_runs', [])
    if runs:
        ids.append(runs[0].get('job_run_id', ''))
for rid in ids[:3]:
    if rid:
        print(rid)
")
for RUN_ID in $SAMPLE_RUN_IDS; do
    python3 "$CI_SKILLS/fetch-job-run-summary/fetch_job_run_summary.py" \
        "$RUN_ID" --format json \
        2>/dev/null > /dev/null || echo "  Warning: job run summary fetch failed for $RUN_ID" >&2
done

# Step 5: Fetch related triages
echo "[5/8] Fetching related triages..." >&2
python3 "$CI_SKILLS/fetch-related-triages/fetch_related_triages.py" \
    "$REGRESSION_ID" --format json \
    2>/dev/null > /dev/null || echo "  Warning: related triages fetch failed" >&2

# Step 6: Fetch JIRA issues (if triaged)
echo "[6/8] Fetching JIRA issues..." >&2
JIRA_KEYS=$(echo "$REGRESSION_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('triages', []):
    k = t.get('jira_key', '')
    if k:
        print(k)
" 2>/dev/null)
if [ -n "$JIRA_KEYS" ]; then
    for KEY in $JIRA_KEYS; do
        python3 "$CI_SKILLS/fetch-jira-issue/fetch_jira_issue.py" \
            "$KEY" --format json \
            2>/dev/null > /dev/null || echo "  Warning: JIRA fetch failed for $KEY (credentials may not be set)" >&2
    done
else
    echo "  No triages found, skipping JIRA fetch" >&2
fi

# Step 7: List regressions (same test name)
echo "[7/8] Fetching related regressions..." >&2
VIEW="${RELEASE}-main"
python3 "$TEAMS_SKILLS/list-regressions/list_regressions.py" \
    --view "$VIEW" --test-name "$TEST_NAME" \
    2>/dev/null > /dev/null || echo "  Warning: list regressions fetch failed" >&2

# Step 8: Fetch historical test runs (for regression start analysis)
echo "[8/8] Fetching historical test runs..." >&2
MOST_FAILED_JOB=$(echo "$REGRESSION_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
jobs = d.get('sample_failed_jobs', {})
if jobs:
    best = max(jobs.items(), key=lambda x: len(x[1].get('failed_runs', [])))
    print(best[0])
" 2>/dev/null)
if [ -n "$MOST_FAILED_JOB" ] && [ -n "$TEST_ID" ]; then
    python3 "$CI_SKILLS/fetch-test-runs/fetch_test_runs.py" \
        "$TEST_ID" --include-success --job-contains "$MOST_FAILED_JOB" \
        --start-days-ago 28 --exclude-output --format json \
        2>/dev/null > /dev/null || echo "  Warning: historical test runs fetch failed" >&2
fi

# Write input.yaml if it doesn't exist
INPUT_YAML="$CASE_DIR/input.yaml"
if [ ! -f "$INPUT_YAML" ]; then
    echo "regression_id: $REGRESSION_ID" > "$INPUT_YAML"
    echo "" >&2
    echo "Created $INPUT_YAML" >&2
fi

# Summary
RESPONSE_COUNT=$(ls "$EVAL_SNAPSHOT_DIR/http_responses/"*.json 2>/dev/null | grep -v index.json | wc -l | tr -d ' ')
echo "" >&2
echo "Snapshot recording complete." >&2
echo "  Responses captured: $RESPONSE_COUNT" >&2
echo "  Index: $EVAL_SNAPSHOT_DIR/http_responses/index.json" >&2
echo "" >&2
echo "Next steps:" >&2
echo "  1. Create $CASE_DIR/annotations.yaml with expected outcomes" >&2
echo "  2. Run /eval-run --config plugins/ci/evals/eval-analyze-regression.yaml" >&2
