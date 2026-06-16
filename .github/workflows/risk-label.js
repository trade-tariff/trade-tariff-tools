module.exports = async ({ github, context, core }) => {
  const body = context.payload.pull_request.body || "";
  const prNumber = context.payload.pull_request.number;

  const GREEN = "🟢";
  const AMBER = "🟠";
  const RED = "🔴";

  const LABEL_LOW = "low-risk";
  const LABEL_MEDIUM = "medium-risk";
  const LABEL_HIGH = "high-risk";
  const RISK_LABELS = [LABEL_LOW, LABEL_MEDIUM, LABEL_HIGH];

  // Check that the repo has the risk labels set up before proceeding.
  // Repos without them configured are silently skipped.
  const { data: repoLabels } = await github.rest.issues.listLabelsForRepo({
    owner: context.repo.owner,
    repo: context.repo.repo,
    per_page: 100,
  });

  const repoLabelNames = repoLabels.map((l) => l.name);
  const hasRiskLabels = RISK_LABELS.every((l) => repoLabelNames.includes(l));

  if (!hasRiskLabels) {
    core.notice(
      "Risk labels (low-risk, medium-risk, high-risk) are not configured in this repo — skipping.",
    );
    return;
  }

  const { data: currentLabels } = await github.rest.issues.listLabelsOnIssue({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: prNumber,
  });

  // Dependabot PRs are dependency bumps with no API changes — always low-risk.
  if (context.payload.pull_request.user.login === "dependabot[bot]") {
    for (const label of currentLabels) {
      if (RISK_LABELS.includes(label.name) && label.name !== LABEL_LOW) {
        await github.rest.issues.removeLabel({
          owner: context.repo.owner,
          repo: context.repo.repo,
          issue_number: prNumber,
          name: label.name,
        });
      }
    }
    if (!currentLabels.find((l) => l.name === LABEL_LOW)) {
      await github.rest.issues.addLabels({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: prNumber,
        labels: [LABEL_LOW],
      });
    }
    return;
  }

  const existingRiskLabel = currentLabels.find((l) =>
    RISK_LABELS.includes(l.name),
  );

  // Extract everything before **Reason for rating:** so that emoji in
  // the template guidance sections below don't interfere with detection.
  // Fall back to an already-applied risk label (e.g. set manually).
  const riskSection =
    (body.match(/([\s\S]*?)\*\*Reason for rating:\*\*/i) || [])[1] || "";
  const lineHasGreen = riskSection.includes(GREEN);
  const lineHasAmber = riskSection.includes(AMBER);
  const lineHasRed = riskSection.includes(RED);
  const lineCount = [lineHasGreen, lineHasAmber, lineHasRed].filter(
    Boolean,
  ).length;

  let detectedLabel = null;

  if (lineCount === 1) {
    if (lineHasRed) detectedLabel = LABEL_HIGH;
    else if (lineHasAmber) detectedLabel = LABEL_MEDIUM;
    else detectedLabel = LABEL_LOW;
  } else if (existingRiskLabel) {
    detectedLabel = existingRiskLabel.name;
  }

  if (!detectedLabel) {
    core.setFailed(
      lineCount > 1
        ? 'Multiple risk emoji found before "Reason for rating:" — please keep exactly one of 🟢, 🟠, 🔴.'
        : 'No risk level found. Add exactly one of 🟢, 🟠, or 🔴 before "Reason for rating:", or apply a risk label manually.',
    );
    return;
  }

  // Remove stale risk labels before applying the detected one.
  for (const label of currentLabels) {
    if (RISK_LABELS.includes(label.name) && label.name !== detectedLabel) {
      await github.rest.issues.removeLabel({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: prNumber,
        name: label.name,
      });
    }
  }

  if (!existingRiskLabel || existingRiskLabel.name !== detectedLabel) {
    await github.rest.issues.addLabels({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: prNumber,
      labels: [detectedLabel],
    });
  }

  if (detectedLabel === LABEL_HIGH) {
    core.setFailed(
      "🔴 This PR is rated HIGH RISK. An admin must bypass branch protection to merge it.",
    );
  }
};
