#!/usr/bin/env bash
# Verify the pull request is ready for auto-merge and its current head is green.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-pull-request-state-gate.sh --repo <owner/name> --pr <number> --workflow <workflow> [--head <expected-oid>]
EOF
}

repo=""
pr=""
workflow=""
expected_head=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --pr)
      pr="$2"
      shift 2
      ;;
    --workflow)
      workflow="$2"
      shift 2
      ;;
    --head)
      expected_head="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$repo" || -z "$pr" || -z "$workflow" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

pull_request="$(gh pr view "$pr" \
  --repo "$repo" \
  --json headRefOid,isDraft,statusCheckRollup)"
head_oid="$(jq -r '.headRefOid' <<< "$pull_request")"

if [[ -n "$expected_head" && "$head_oid" != "$expected_head" ]]; then
  echo "PR #$pr head changed from $expected_head to $head_oid; blocking auto-merge." >&2
  exit 1
fi

if [[ "$(jq -r '.isDraft' <<< "$pull_request")" == "true" ]]; then
  echo "PR #$pr is still a draft; blocking auto-merge." >&2
  exit 1
fi

runs="$(gh run list \
  --repo "$repo" \
  --workflow "$workflow" \
  --commit "$head_oid" \
  --limit 20 \
  --json headSha,status,conclusion,createdAt)"
current_run="$(jq -c --arg head "$head_oid" '
  map(select(.headSha == $head))
  | sort_by(.createdAt)
  | last // empty
' <<< "$runs")"

if [[ -z "$current_run" ]]; then
  echo "No $workflow run exists for the current head of PR #$pr; blocking auto-merge." >&2
  exit 1
fi

run_status="$(jq -r '.status' <<< "$current_run")"
if [[ "$run_status" != "completed" ]]; then
  echo "The current-head $workflow run for PR #$pr is $run_status; blocking auto-merge." >&2
  exit 1
fi

run_conclusion="$(jq -r '.conclusion' <<< "$current_run")"
if [[ "$run_conclusion" != "success" ]]; then
  echo "The current-head $workflow run for PR #$pr concluded $run_conclusion; blocking auto-merge." >&2
  exit 1
fi

blocking_checks="$(jq -c '
  def acceptable_conclusion:
    . == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL";
  [
    (.statusCheckRollup // [])[]
    | select((.workflowName // "") != "Auto-merge low-risk PRs")
    | if .__typename == "StatusContext" then
        select(.state != "SUCCESS")
        | {
            label: (.context // "(unnamed status)"),
            result: (.state // "UNKNOWN")
          }
      else
        select(
          .status != "COMPLETED"
          or ((.conclusion // "") | acceptable_conclusion | not)
        )
        | {
            label: (
              if (.workflowName // "") == "" then
                (.name // "(unnamed check)")
              else
                "\(.workflowName) / \(.name // "(unnamed check)")"
              end
            ),
            result: (
              if .status != "COMPLETED" then
                .status
              else
                (.conclusion // "UNKNOWN")
              end
            )
          }
      end
  ]
' <<< "$pull_request")"
blocking_count="$(jq 'length' <<< "$blocking_checks")"

if [[ "$blocking_count" -gt 0 ]]; then
  noun="checks have"
  if [[ "$blocking_count" -eq 1 ]]; then
    noun="check has"
  fi
  echo "$blocking_count current-head $noun not completed successfully for PR #$pr:" >&2
  jq -r '.[] | "  - \(.label): \(.result)"' <<< "$blocking_checks" >&2
  exit 1
fi
