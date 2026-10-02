#!/usr/bin/env bash
# Prints the compiler and self-test diagnostics from the most recent CI run.
#
# Runner logs and artifacts are served from hosts this sandbox cannot reach, but
# annotations come back through api.github.com. The workflow re-emits compiler
# diagnostics as annotations precisely so this script can read them; without it
# the only visible signal would be an exit code.
#
# Notice-level annotations are included on purpose: the workflow emits them
# unconditionally to prove the reporting path works, and filtering to failures
# alone hid three consecutive runs of that evidence.
#
# Usage: Tools/ci-errors.sh [run-id]
set -uo pipefail

run_id="${1:-}"
if [ -z "$run_id" ]; then
  run_id=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')
fi

echo "run: $run_id"
gh run view "$run_id" 2>&1 | sed -n '/^JOBS/,/^ANNOTATIONS/p' | head -45

# Noise that carries no information: driver command lines, progress output, and
# the two runner-image advisories GitHub attaches to every job.
noise='builtin-SwiftDriver|Building for debugging|\[Planning|\[Pre-planning|\[Computing|^Compiling|^Emitting|^Write |^Planning|^Linking|cd /Users|Node.js 20 is deprecated|ubuntu-latest label will migrate'

echo
echo "===== diagnostics ====="
for job in $(gh run view "$run_id" --json jobs --jq '.jobs[] | select(.conclusion=="failure") | .databaseId'); do
  name=$(gh api "repos/:owner/:repo/check-runs/$job" --jq '.name' 2>/dev/null)
  echo "--- ${name:-job $job} ---"
  gh api "repos/:owner/:repo/check-runs/$job/annotations" --paginate \
    --jq '.[] | select(.annotation_level != "warning") | "\(.annotation_level): \(.message)"' 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
    | grep -vE "$noise" \
    | cut -c1-4000 \
    | sort -u | head -80
done
