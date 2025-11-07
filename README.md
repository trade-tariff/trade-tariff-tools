# trade-tariff-tools

This repo is used as a wastebasket for general workflows and scripts that the tariff team need as part of our release and other processes.

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
   pip install requests openpyxl
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
   - Configure credentials: `aws configure`
   - Or pull credentials from: https://d-9c677042e2.awsapps.com/start/

4. **Verify Session Manager Plugin installation:**
   ```bash
   session-manager-plugin
   ```
   You should see usage information if it's installed correctly.

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
```

**Features:**
- Interactive selection of clusters, services, and tasks using `fzf`
- Automatically starts `backend-job` tasks if none are running
- Automatically stops `backend-job` tasks when you exit
- Sets `RAILS_LOG_LEVEL=debug` for all commands

**Note:** The script requires Session Manager Plugin to be installed. If you encounter an error about SessionManagerPlugin not being found, install it using:
```bash
brew install session-manager-plugin
```

### 3. `bin/ott_search_stat.py`

Performs OTT (Online Trade Tariff) searches and outputs results to an Excel file.

**Setup:**
- Edit `queries.txt` with your search queries (one per line)

**Usage:**
```bash
python3 bin/ott_search_stat.py
```

**Output:** Creates `search_results.xlsx` with three sheets:
- "Commodity Match" - Top 5 commodity matches
- "Results" - Reference match results
- "Other Results" - Other search results

**Configuration:** The script currently points to `http://localhost:3000`. You may need to modify the `url` variable in the script (line 32) to point to your desired environment.
