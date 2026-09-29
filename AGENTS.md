# AGENTS.md

This file is the repo-local development guide for `trade-tariff-tools`. Read
it as standalone project context for a fresh checkout.

## What This Repo Is

`trade-tariff-tools` is a shared utility repository for the Trade Tariff team.
It contains:

- Reusable GitHub Actions workflows under `.github/workflows/`
- Composite GitHub Actions under `.github/actions/`
- Public operational commands under `bin/`
- Script implementations and private shell libraries under `scripts/`
- Bats regression tests under `tests/`
- A Nix flake that packages the interactive `ecs` command

Treat the GitHub Actions and shell commands as public APIs used by other
Trade Tariff repositories. Backward compatibility matters.

## Development Workflow

- Keep changes small and targeted. This repository is consumed by other Trade
  Tariff repositories, so workflow and command interfaces are compatibility
  boundaries.
- For failing Bats tests, GitHub Actions regressions, shell behavior changes,
  Terraform/AWS deployment issues, or unexpected command output, first find the
  root cause and add a regression test where practical.
- Before opening a PR, run the relevant verification commands and include the
  results in the PR body.
- For multi-step work, keep a short checklist in the PR description or commit
  notes so reviewers can see what changed and how it was checked.

## Local Setup

- Do not assume every contributor has Nix. Put normal commands first in docs
  and PR notes.
- Use the system package manager or project-standard tooling appropriate for
  your machine to provide local development dependencies.
- If Nix is available, it is a convenient non-mutating way to run temporary
  tools, but it is optional.
- `flake.nix` packages `bin/ecs` with `awscli2`, `jq`, `fzf`, and
  `ssm-session-manager-plugin`.
- Python scripts currently depend on `requests` and `openpyxl`.
- AWS-oriented commands expect valid AWS credentials and generally operate in
  `eu-west-2`.

Useful commands:

```bash
bats tests
for file in bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh tests/test_helper.bash; do bash -n "$file"; done
shellcheck bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh
```

Nix equivalents when the local environment supports them:

```bash
nix build .#ecs
nix shell nixpkgs#bats -c bats tests
nix shell nixpkgs#shellcheck -c shellcheck bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh
```

## Verification

The CI workflow proves the repository with Bash syntax checks and Bats tests.
Run the same checks locally when touching scripts, tests, workflows, or
composite actions:

```bash
for file in bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh tests/test_helper.bash; do bash -n "$file"; done
bats tests
```

`bash -n` checks only its first file argument. Always loop over files.

On macOS the system Bash is 3.2 and `date` is BSD. Some tests fail there. Run
Bats in a Linux container that matches CI, for example:

```bash
docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 bash -c 'apt-get update -qq && apt-get install -y -qq bats jq git ruby >/dev/null && git config --global --add safe.directory /repo && bats tests'
```

If `bats` is unavailable, install or provide it through your normal local
environment. If Nix is available, this is a non-mutating option:

```bash
nix shell nixpkgs#bats -c bats tests
```

Also run targeted command checks for the thing you changed, for example:

```bash
TRACE=1 ./bin/run-task -h
./bin/cleanup-ecs-families --help
./bin/rotate-task-definitions 4
```

Do not rely on inspection alone for behavior changes. Report the exact
commands run and whether they passed.

## Shell Script Conventions

Public commands live in `bin/` and private shell libraries live in
`scripts/lib/`. Tests assert this layout.

New public `bin/` entrypoints must:

- Be executable Bash scripts with no file extension.
- Use hyphenated lowercase command names: `name`, `name-with-parts`.
- Start with this exact topmatter:

```bash
#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber
```

Executable shell scripts under `scripts/` must use the same topmatter unless
they are private libraries under `scripts/lib/`.

Shell implementation guidance:

- Quote variables unless word splitting is intentional.
- Prefer arrays for argv construction.
- Keep destructive AWS operations behind explicit modes or flags.
- Preserve default report/dry-run behavior for cleanup tools.
- Keep `TRACE=1` useful for debugging.
- Write clear `--help` output for public commands.
- Use `mktemp` plus `trap` for temporary files.
- Avoid parsing JSON with ad hoc text tools when `jq` is available.

## Workflow Script Conventions

Workflow and composite action YAML does orchestration only. Put logic in
scripts so that it can be run locally, reviewed, and tested with Bats.

### When to use a script

Move a `run:` block to a script when it has more than about 15 lines of logic,
or any loop or branch. Setup one-liners stay inline.

### Where scripts live

| Owner | Location | How the caller finds it |
|---|---|---|
| One composite action | `.github/actions/<action>/<verb-noun>.sh` | `"${{ github.action_path }}/<verb-noun>.sh"` |
| Two sibling actions | In one of the action directories | `"${{ github.action_path }}/../<other-action>/<verb-noun>.sh"` |
| A reusable workflow | In a composite action that the workflow uses | `uses: trade-tariff/trade-tariff-tools/.github/actions/<action>@main` |
| A workflow that runs only in this repo | `scripts/<verb-noun>.sh` | `scripts/<verb-noun>.sh` after `actions/checkout` |

A reusable workflow runs in the caller repository, so `github.action_path` is
not available to it. Do not put logic in a reusable workflow. Call a
first-party composite action.

Exception: `deploy-ecs.yml` checks out this repository at `job.workflow_sha`
into `.trade-tariff-tools` and runs `scripts/*.sh`. Use this only when the
script version must match the reusable workflow SHA exactly.

### Script contract

- Lines 1-7 are the standard topmatter (see "Shell Script Conventions").
- Next is a `usage()` heredoc. It documents Usage, purpose, Arguments,
  Environment (required or optional, with defaults), Outputs, and Exit codes.
  `-h` and `--help` print it.
- GitHub context values enter only through `env:`. A script never contains
  `${{ }}`. In `run:`, the only expression is `${{ github.action_path }}`.
- Flags are for values a person types for a local run. Environment variables
  are for values the runner supplies.
- A missing required environment variable exits 2 with
  `Missing required environment variable: NAME`.
- Write outputs to `"${GITHUB_OUTPUT:-/dev/stdout}"`.
- Exit codes: 0 success, 1 failure, 2 usage error.
- Commit scripts as executable (`100755`).
- Add a Bats test that runs the script with stubbed external commands, and a
  contract test that greps the YAML for the script call and its `env:` wiring.

Example:

```yaml
- shell: bash
  env:
    STALE_DAYS: ${{ inputs.stale_days }}
  run: '"${{ github.action_path }}/close-stale-pull-requests.sh"'
```

## Existing Command Contracts

- `bin/ecs` is the interactive ECS helper. It depends on AWS CLI, `jq`, `fzf`,
  and Session Manager Plugin. It also supports `logs` and `run` subcommands.
- `bin/run-task` starts ECS tasks and accepts explicit task definition ARNs.
- `bin/db-migrate` derives the job task from `--app-name` by stripping the
  `tariff-` prefix and appending `-job`. Backend migrations run both UK and XI
  tasks.
- `bin/cleanup-ecs-families` defaults to report mode and preserves job task
  families.
- `bin/rotate-task-definitions` is the canonical rotation command.
  `bin/rotate-revisions` is deprecated and only delegates to it.
- `bin/fetch-commodities` and `bin/ott-search-stat` are Bash wrappers around
  Python scripts.

Do not rename or remove public commands without updating workflows, README, and
tests.

## Bats Testing Patterns

- Tests live in `tests/*.bats` and load `tests/test_helper.bash`.
- Prefer stubbing external commands by prepending a temporary `bin` directory
  to `PATH`.
- Capture command arguments/output in temporary files and assert behavior from
  those files.
- Use the helper assertions in `tests/test_helper.bash`.
- Add or update regression tests for workflow/action contracts, not just shell
  functions. Several tests intentionally grep workflow YAML for required
  wiring.

## GitHub Actions And Workflow Guidance

This repo publishes reusable workflows and composite actions. Changes can
affect many downstream repos, so keep interfaces deliberate.

Best practices to follow:

- Use least-privilege `permissions:` at workflow or job level. GitHub's own
  guidance is to grant the `GITHUB_TOKEN` only the minimum required access:
  https://docs.github.com/actions/reference/authentication-in-a-workflow
- Prefer `permissions: {}` or `contents: read` by default, then add only the
  scopes a job actually needs, such as `pull-requests: write` for PR comments
  or `id-token: write` for OIDC.
- Use OIDC for AWS access. Jobs that need AWS role assumption require
  `id-token: write`; jobs that do not use AWS should not request it:
  https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
- Pin third-party actions to immutable full-length commit SHAs by default.
  GitHub documents full-length SHA pinning as the strongest immutable option.
  Version tags are easier for Dependabot to update and this repo currently uses
  them in several places; treat that as current practice, not the security
  ideal, and do not introduce new floating branch refs for third-party actions:
  https://docs.github.com/en/actions/reference/security/secure-use
- Keep first-party reusable actions and workflows under
  `trade-tariff/trade-tariff-tools/...@main` unless you are deliberately
  introducing a release/tag strategy for consumers. This is a downstream
  compatibility convention for this repo, not a general third-party action
  security rule.
- Use composite actions for shared step sequences and reusable workflows for
  shared jobs or deployment flows.
- Define every composite action input with `description`, `required`, and a
  safe `default` where optional.
- In composite actions, set `shell: bash` for `run:` steps.
- Treat workflow inputs, PR titles, branch names, issue text, labels, and other
  GitHub contexts as untrusted. Prefer passing values through `env:` and quote
  them in Bash instead of interpolating expressions directly into scripts.
- Do not echo secrets. Mask any secret-derived values before logging them.
- Avoid `pull_request_target` unless the workflow has been explicitly designed
  not to checkout or execute untrusted fork code with privileged tokens.
- Avoid `curl | bash` installers. If an installer is unavoidable, pin the
  version and verify the source/checksum where the tool supports it.
- Keep Slack notifications low-noise and tied to actionable success/failure or
  deployment outcomes.
- Add `timeout-minutes` to long-running jobs where a hang would be expensive.
- Use `concurrency:` for deployment, service-control, and maintenance workflows
  when overlapping runs could fight over Terraform state or ECS desired counts.
- Use `if: always()` intentionally for cleanup/notification jobs, and make the
  result logic explicit.
- For deployment and maintenance workflows, keep environment/account/role
  derivation centralized through `.github/actions/configure-environment`.

Repository-specific workflow contracts:

- `ci.yml` is path-filtered. If you add a new first-party script, action
  helper, or workflow contract test, update the path filters so CI runs on
  relevant PRs.
- `configure-environment` is the source of truth for account IDs, deploy roles,
  cleanup roles, ECS cluster names, log groups, security group names, ECR URLs,
  and Slack channels.
- Service start/stop actions must consume `configure-environment` outputs for
  cluster and role selection.
- Cleanup and rotation workflows must use the cleanup role from
  `configure-environment`.
- `db-migrate` orchestration belongs in `bin/db-migrate`; the composite action
  delegates to that command and must not checkout the caller repository.
- Terraform actions use `hashicorp/setup-terraform` and force-unlock on
  cancellation. Preserve this behavior unless replacing it with a tested
  equivalent.

## Terraform, AWS, And Deployments

- Be conservative around production. Prefer report modes, explicit
  environments, and small diffs.
- Valid environments are `development`, `staging`, and `production`.
- Deployment roles differ for `tariff-identity` and `identity` service control.
  Preserve this behavior in `configure-environment`.
- Production ECR is used for image URLs derived by `configure-environment`.
- Scheduled job task families ending in `-job` or containing an account suffix
  after `-job` are preserved by cleanup logic.
- Task definition inventory helpers live in
  `scripts/lib/ecs-task-definitions.sh`; keep shared ECS family logic there.

## Python Scripts

- Keep `bin/` wrappers as the public entrypoints.
- Avoid adding global Python packaging unless the repo is intentionally being
  turned into a packaged Python project.
- For `fetch-commodities`, remember staging is used to resolve commodity
  metadata, but generated links point at production for Stop Press Notices.
- For `ott-search-stat`, the default URL is `http://localhost:3000`.

## Pull request writing

Write all pull request titles and descriptions in ASD-STE100 Simplified Technical English.

- Write short sentences. Put one fact or one instruction in each sentence.
- Use the same word for the same thing. Do not use synonyms.
- Use active voice.
- Use simple present tense for facts. Use simple past tense for completed work.
- Use words that a general technical reader can understand. Keep product names and legal terms when they are necessary.
- Do not write long noun clusters.
- Do not write filler, marketing language, or vague claims.
- Follow the repository pull request template. Fill each required section with concrete facts.
- Write for the reviewer. Do not write a work diary.

## Pull Requests And Commits

- Follow the repo PR template in `.github/pull_request_template.md`.
- Use conventional commit subjects and keep Jira/ticket keys in the body or
  footer, not the subject.
- If there is no ticket, include `Issue: No ticket/issue`.
- Avoid noisy notification changes unless the PR explains the operational need.
