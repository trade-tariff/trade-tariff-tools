#!/usr/bin/env bash
# Orchestrate current-head review, pull-request state, approval, and merge gates.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: auto-merge.sh --repo <owner/name> --pr <number> --label <label> \
  --merge-method <merge|squash|rebase> --required-workflow <workflow> \
  [--event-action <action>] [--event-label <label>]
EOF
}

repo=""
pr=""
label=""
merge_method=""
required_workflow=""
event_action=""
event_label=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --merge-method) merge_method="$2"; shift 2 ;;
    --required-workflow) required_workflow="$2"; shift 2 ;;
    --event-action) event_action="$2"; shift 2 ;;
    --event-label) event_label="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$repo" || -z "$pr" || -z "$label" || -z "$merge_method" || -z "$required_workflow" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

case "$merge_method" in
  merge|squash|rebase) ;;
  *)
    echo "::error::Invalid merge-method: $merge_method (expected merge, squash, or rebase)" >&2
    exit 1
    ;;
esac

action_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
approval_script="$action_path/approve-pull-request.sh"
disable_script="$action_path/disable-auto-merge.sh"
gate_script="$action_path/check-copilot-review-gate.sh"
state_gate_script="$action_path/check-pull-request-state-gate.sh"
request_script="$action_path/request-copilot-review.sh"

for helper in "$approval_script" "$disable_script" "$gate_script" "$state_gate_script" "$request_script"; do
  if [[ ! -f "$helper" ]]; then
    echo "::error::Missing ${helper}" >&2
    exit 1
  fi
  chmod +x "$helper"
done

"$disable_script" --repo "$repo" --pr "$pr" --merge-method "$merge_method"

# Label removal only needs to disarm any legacy auto-merge request.
if [[ "$event_action" == "unlabeled" && "$event_label" == "$label" ]]; then
  exit 0
fi

labels="$(gh pr view "$pr" --repo "$repo" --json labels -q '.labels[].name')"
if ! grep -qx "$label" <<< "$labels"; then
  echo "PR #$pr does not have the ${label} label; skipping."
  exit 0
fi

expected_head="$(gh pr view "$pr" --repo "$repo" --json headRefOid -q '.headRefOid')"

set +e
"$gate_script" --repo "$repo" --pr "$pr" --head "$expected_head"
gate_status=$?
set -e

if [[ "$gate_status" -eq 2 ]]; then
  "$request_script" --repo "$repo" --pr "$pr"
  echo "Waiting for Copilot to review PR #$pr; auto-merge will be retried on the next workflow run."
  exit 0
fi
if [[ "$gate_status" -ne 0 ]]; then
  echo "Copilot review requirements not met for PR #$pr; skipping auto-merge."
  exit 0
fi

set +e
"$state_gate_script" \
  --repo "$repo" \
  --pr "$pr" \
  --workflow "$required_workflow" \
  --head "$expected_head"
state_gate_status=$?
set -e

if [[ "$state_gate_status" -ne 0 ]]; then
  echo "Pull request state or workflow requirements not met for PR #$pr; skipping auto-merge."
  exit 0
fi

"$approval_script" --repo "$repo" --pr "$pr" --head "$expected_head"

echo "Merging PR #$pr at $expected_head (${merge_method})"
gh pr merge "$pr" \
  --repo "$repo" \
  "--${merge_method}" \
  --match-head-commit "$expected_head"
