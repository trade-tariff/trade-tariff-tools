# Authorize development deployment

Use this action in a separate authorization job with `contents: read` only.
It checks out the caller's current default branch, reads a JSON account list,
and returns an exact commit SHA. It does not assume an AWS role or deploy code.

The caller must use `pull_request_target` for PR deployments and restrict its
base branch to the default branch. Run the authorization job only when the PR
has the deployment label. Do not check out PR code in that job. Manual
`workflow_dispatch` runs must also use the default branch.

## Inputs and outputs

- `approved-accounts-file`: Path to a JSON array of external GitHub logins in the
  caller repository. Default: `.github/approved-fork-deployers.json`.
- Output `sha`: The full authorized commit SHA. Pass it to the deployment job's
  checkout input. Do not resolve the PR branch again after authorization.

Example account list:

```json
["approved-contributor"]
```

Both the PR author and the owner of its fork must be approved. The original
triggering account and the account that reruns a job must each be approved or
have repository write access. Repository writers can still deploy upstream PRs
and use manual dispatch. Manual dispatch resolves the caller's optional `sha`
input, or the workflow commit, to a full commit SHA.

Example authorization job:

```yaml
permissions:
  contents: read

jobs:
  authorize:
    if: >
      github.event_name == 'workflow_dispatch' ||
      (contains(github.event.pull_request.labels.*.name, 'needs-deployment') &&
       (github.event.action != 'labeled' || github.event.label.name == 'needs-deployment'))
    runs-on: ubuntu-latest
    outputs:
      sha: ${{ steps.authorize.outputs.sha }}
    steps:
      - uses: trade-tariff/trade-tariff-tools/.github/actions/authorize-development-deployment@main
        id: authorize
```

The deployment job must declare `needs: authorize`. Give OIDC permission and
secrets only to the deployment jobs. Use
`${{ needs.authorize.outputs.sha }}` as the deployment commit. Put deployment
concurrency on that job, not on the workflow, so denied requests cannot cancel
an authorized deployment.

## Trust boundary

An approved account can supply build and Terraform code to the deployment jobs.
Approval trusts that code with the existing deployment credentials. It is not a
sandbox and does not reduce the IAM role's permissions. Review account-list
changes and changes to build scripts or Terraform. The action reads the current
account list on each run, including reruns. Removing an account prevents new
authorization decisions; it does not cancel jobs already authorized.
