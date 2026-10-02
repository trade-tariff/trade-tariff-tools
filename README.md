# trade-tariff-tools

This repository provides shared GitHub Actions workflows, composite actions and
operational commands for the Trade Tariff team. Other repositories consume these
interfaces, so changes must preserve compatibility or coordinate a migration.

- [.github/workflows/](.github/workflows/): reusable workflows and automation.
- [.github/actions/](.github/actions/): composite actions.
- [bin/](bin/): public commands.
- [scripts/](scripts/): implementations and internal helpers.
- [tests/](tests/): Bats regression tests.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the fork workflow, review process and
private security reporting. Operational commands can run jobs, change data or
remove AWS resources. Confirm the target account and obtain approval before
using a command that changes shared resources.

## Setup Guide

### Prerequisites

- **Python 3.11.4+** (or recent 3.x)
- **pip** (Python package manager)
- **For the `ecs` script:**
  - AWS CLI configured with credentials
  - Session Manager Plugin
  - `jq` (JSON processor)
  - `fzf` (fuzzy finder)

### Installation Steps

1. **Install Python dependencies:**

   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   python3 -m pip install requests openpyxl
   ```

2. **Install system dependencies (for macOS):**

   ```bash
   # Install AWS CLI
   brew install awscli

   # Install Session Manager Plugin
   brew install session-manager-plugin

   # Install jq (JSON processor)
   brew install jq

   # Install fzf (fuzzy finder)
   brew install fzf
   ```

3. **Configure AWS credentials (for `ecs` script):**
   - Use the approved role through the [AWS access portal](https://d-9c677042e2.awsapps.com/start/).

4. **Verify Session Manager Plugin installation:**

   ```bash
   session-manager-plugin
   ```

   You should see usage information if it's installed correctly.

## Check changes

Run `bats tests` for the shell regression suite. Use `bash -n` on changed Bash
scripts and `shellcheck` for static analysis. See [AGENTS.md](AGENTS.md) and
[CI](.github/workflows/ci.yml) for the full command list.

AWS access is not needed just to review documentation. Do not run the operational
examples below as smoke tests against a shared account.

## Licence

The code and associated documentation use the [MIT licence](LICENCE.md), with
Crown copyright (HM Revenue & Customs). Dependencies and third-party actions
retain their own licences.

## Usage Guide

### 1. `bin/fetch-commodities`

Fetches commodity codes and descriptions from the Trade Tariff service API and generates a markdown table.

**Setup:**

- Edit `commodities.txt` with your commodity codes (one per line)

**Usage:**

```bash
./bin/fetch-commodities
```

**Output:** Prints a markdown table with commodity codes and descriptions that can be copied into Stop Press Notices.

For example, this will produce:

| Commodity Code | Description |
| -------------- | ----------- |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/3824999214" target="_blank">3824999214</a> | Other |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209831" target="_blank">1516209831</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209822" target="_blank">1516209822</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209823" target="_blank">1516209823</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209832" target="_blank">1516209832</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009122" target="_blank">1518009122</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009123" target="_blank">1518009123</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009131" target="_blank">1518009131</a> | Consigned from the United Kingdom |

### 2. `bin/ecs`

Interactive script to execute commands in AWS ECS tasks. Uses `fzf` for interactive selection of clusters, services, and tasks.

**Usage:**

```bash
# Interactive shell (default)
./bin/ecs

# Run a specific command
./bin/ecs 'bundle exec rails console'

# Run a rake task
./bin/ecs 'bundle exec rake tariff:jobs'

# Select and run a scheduled job from the current AWS account
./bin/ecs run

# Run a scheduled job by name from the current AWS account
./bin/ecs run backend-database-replication

# Run the replication job without prompts and without tailing logs
./bin/ecs run --yes --no-tail backend-database-replication

# Filter explicitly if a job name exists in more than one environment in the account
./bin/ecs run --environment staging --yes --no-tail backend-database-replication
```

`ecs run` discovers scheduled jobs from the AWS account represented by your
current credentials. Use `--environment` only as a filter when that account has
more than one matching environment.

**Features:**

- Interactive selection of clusters, services, and tasks using `fzf`
- Starts scheduled EventBridge-backed ECS jobs on demand with `ecs run`
- Discovers scheduled jobs from the current AWS account credentials
- Resolves the latest active task definition before starting scheduled jobs
- Lists every job (`admin-job`, `backend-job`, `dev-hub-job`, `identity-job`, ...) next to the ECS services
- Reuses a running job task that has ECS Exec enabled, or starts a new one if none exists
- Automatically stops the job tasks that it started when you exit
- Sets `RAILS_LOG_LEVEL=debug` for all commands

**Note:** The script requires Session Manager Plugin to be installed. If you encounter an error about SessionManagerPlugin not being found, install it using:

```bash
brew install session-manager-plugin
```

### 3. `bin/ott-search-stat`

Performs OTT (Online Trade Tariff) searches and outputs results to an Excel file.

**Setup:**

- Edit `queries.txt` with your search queries (one per line)

**Usage:**

```bash
./bin/ott-search-stat
```

**Output:** Creates `search_results.xlsx` with three sheets:

- "Commodity Match" - Top 5 commodity matches
- "Results" - Reference match results
- "Other Results" - Other search results

**Configuration:** The script currently points to `http://localhost:3000`. You may need to modify the `url` variable in the script (line 32) to point to your desired environment.

### 4. `bin/cleanup-ecs-families`

This script reports on and optionally deregisters unused Amazon ECS task definition families. It is designed to help keep your ECS task definitions clean by identifying and removing old, inactive families that are no longer associated with active services or recently run tasks.

**Important Safeguards:**

- Task definition families ending in `-job` are preserved from family cleanup, because scheduled job families are not necessarily attached to ECS services.
- It also considers families of recently running or stopped tasks as 'in-use' for a short period.

**Usage:**

```bash
# Report mode (default): Lists unused task definition families without making any changes.
./bin/cleanup-ecs-families report

# Deregister mode: Deregisters the identified unused task definition families.
./bin/cleanup-ecs-families deregister [--family FAMILY_NAME] [--environment ENV_NAME]
```

**Options:**

- `--family FAMILY_NAME`: Target a specific task definition family for reporting or deregistration.
- `--environment ENV_NAME`: Specify the environment (e.g., `development`, `staging`, `production`). Defaults to `development`.

### 5. `bin/rotate-task-definitions`

Deregisters old, unused ECS task definition revisions, keeping a specified number of recent revisions and all currently in-use revisions.

**Usage:**

```bash
./bin/rotate-task-definitions [number_to_keep]
```

The `number_to_keep` argument is optional and defaults to 4. All revisions currently in use by services or running tasks are always preserved, regardless of this number.

When AWS returns task definitions for a family prefix, the script only deregisters revisions whose exact family matches the family currently being rotated.
