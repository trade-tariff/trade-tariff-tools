#!/usr/bin/env bash
# Report whether Dependabot alone authored the pull request at the expected head.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-dependabot-pull-request.sh --repo <owner/name> --pr <number> --head <expected-oid>

Exits 0 when dependabot[bot] opened the pull request and authored every
commit, GitHub signed every commit, and the last commit is the expected head.
Exits 1 when any of these conditions is false.
Exits 3 when GitHub cannot be read.
EOF
}

repo=""
pr=""
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

if [[ -z "$repo" || -z "$pr" || -z "$expected_head" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

dependabot_login="dependabot[bot]"

if ! author="$(gh api "repos/$repo/pulls/$pr" --jq '.user.login // ""')"; then
  echo "Unable to read PR #$pr." >&2
  exit 3
fi

if [[ "$author" != "$dependabot_login" ]]; then
  echo "PR #$pr is not authored by $dependabot_login."
  exit 1
fi

# One line per commit: sha, then "true" when Dependabot authored the commit
# and GitHub (web-flow) signed it. A person who pushes to the branch, or sets
# a Dependabot author email by hand, fails this check.
if ! commits="$(gh api --paginate "repos/$repo/pulls/$pr/commits" --jq '
  .[]
  | [
      .sha,
      (
        (.author.login // "") == "dependabot[bot]"
        and (.committer.login // "") == "web-flow"
        and (.commit.verification.verified // false) == true
      )
    ]
  | @tsv
')"; then
  echo "Unable to read the commits of PR #$pr." >&2
  exit 3
fi

if [[ -z "$commits" ]]; then
  echo "PR #$pr has no commits."
  exit 1
fi

if grep -q $'\tfalse$' <<< "$commits"; then
  echo "PR #$pr has commits that Dependabot did not author."
  exit 1
fi

last_commit="$(tail -n 1 <<< "$commits" | cut -f 1)"
if [[ "$last_commit" != "$expected_head" ]]; then
  echo "PR #$pr head changed from $expected_head to $last_commit."
  exit 1
fi

echo "PR #$pr contains only Dependabot commits at $expected_head."
