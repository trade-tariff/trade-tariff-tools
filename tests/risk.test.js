import { jest } from '@jest/globals';
import riskLabel from '../.github/actions/risk-label/label';

const labels = [
  { name: 'low-risk' },
  { name: 'medium-risk' },
  { name: 'high-risk' },
];

describe('risk labeler', () => {
  let github;
  let context;
  let core;

  beforeEach(() => {
    core = {
      notice: jest.fn(),
      setFailed: jest.fn(),
    };

    github = {
      rest: {
        issues: {
          listLabelsForRepo: jest.fn(),
          listLabelsOnIssue: jest.fn(),
          removeLabel: jest.fn(),
          addLabels: jest.fn(),
        },
      },
    };

    context = {
      payload: {
        pull_request: {
          number: 9001,
          body: '',
          user: {
            login: 'trade-tariff-continuity-bot',
          },
        },
      },
      repo: {
        owner: 'trade-tariff',
        repo: 'trade-tariff-tools',
      },
    };

    jest.clearAllMocks();
  });

  describe('when risk labels are not configured', () => {
    it('should send notice and stop', async () => {
      github.rest.issues.listLabelsForRepo.mockResolvedValue({
        data: [{ name: 'bug' }, { name: 'feature' }],
      });

      await riskLabel({github, context, core});

      expect(core.notice).toHaveBeenCalledWith(
        'Risk labels (low-risk, medium-risk, high-risk) are not configured in this repo — skipping.',
      );

      expect(github.rest.issues.listLabelsOnIssue).not.toHaveBeenCalled();
    });
  });

  describe('when PR author is dependabot', () => {
    beforeEach(() => {
      context.payload.pull_request.user.login = 'dependabot[bot]';
      github.rest.issues.listLabelsForRepo.mockResolvedValue({
        data: labels,
      });
    });

    it('should remove labels that are not low-risk', async () => {
      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [{ name: 'medium-risk' }],
      });

      await riskLabel({github, context, core});

      expect(github.rest.issues.removeLabel).toHaveBeenCalledWith({
        owner: 'trade-tariff',
        repo: 'trade-tariff-tools',
        issue_number: 9001,
        name: 'medium-risk',
      });
    });

    it('should add low-risk label, if not present', async () => {
      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [],
      });

      await riskLabel({github, context, core});

      expect(github.rest.issues.addLabels).toHaveBeenCalledWith({
        owner: 'trade-tariff',
        repo: 'trade-tariff-tools',
        issue_number: 9001,
        labels: ['low-risk'],
      });
    });

    it('should do nothing if correct label is present', async () => {
      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [{ name: 'low-risk' }],
      });

      await riskLabel({github, context, core});

      expect(github.rest.issues.addLabels).not.toHaveBeenCalled();
    });
  });

  describe('when detecting risk level from PR body', () => {
    beforeEach(() => {
      github.rest.issues.listLabelsForRepo.mockResolvedValue({
        data: labels,
      });

      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [],
      });
    });

    it('should fail when multiple risk emoji are found', async () => {
      context.payload.pull_request.body = `
        **Risk level:** 🟢 / 🟠 / 🔴 <!-- delete as appropriate -->
        **Reason for rating:** Rate the overall risk of deploying this change:
        🟢 Green  – Low risk. Good to go, standard review applies.
        🟠 Amber  – Medium risk. Socialise with the team before merging.
        🔴 Red    – High risk. Requires explicit approval from Thor or Neil before merging.
      `;

      await riskLabel({github, context, core});

      expect(core.setFailed).toHaveBeenCalledWith(
        'Multiple risk emoji found before "Reason for rating:" — please keep exactly one of 🟢, 🟠, 🔴.',
      );
    });

    it('should fail when no risk emoji or label present', async () => {
      context.payload.pull_request.body = `
        **Risk level:** low
        **Reason for rating:** it's fine to merge this one kthxbai
      `;

      await riskLabel({github, context, core});

      expect(core.setFailed).toHaveBeenCalledWith(
        'No risk level found. Add exactly one of 🟢, 🟠, or 🔴 before "Reason for rating:", or apply a risk label manually.',
      );
    });
  });

  describe('when risk level has been found', () => {
    beforeEach(() => {
      github.rest.issues.listLabelsForRepo.mockResolvedValue({
        data: labels,
      });
    });

    it('should apply correct label and remove conflicting ones', async () => {
      context.payload.pull_request.body = `
        **Risk level:** 🟢
        **Reason for rating:** no changes
      `;

      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [{ name: 'medium-risk' }],
      });

      await riskLabel({github, context, core});

      expect(github.rest.issues.removeLabel).toHaveBeenCalledWith({
        owner: 'trade-tariff',
        repo: 'trade-tariff-tools',
        issue_number: 9001,
        name: 'medium-risk',
      });

      expect(github.rest.issues.addLabels).toHaveBeenCalledWith({
        owner: 'trade-tariff',
        repo: 'trade-tariff-tools',
        issue_number: 9001,
        labels: ['low-risk'],
      });
    });

    it('should set failure when high-risk label is applied', async () => {
      context.payload.pull_request.body = `
        **Risk level**: 🔴
        **Reason for rating:** high risk, will delete the production database :)
      `;

      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [],
      });

      await riskLabel({github, context, core});

      expect(core.setFailed).toHaveBeenCalledWith(
        '🔴 This PR is rated HIGH RISK. An admin must bypass branch protection to merge it.',
      );
    });

    it('should not modify labels if detected label already applied', async () => {
      context.payload.pull_request.body = `
        **Risk level:** 🟢
        **Reason for rating:** does nothing, actually
      `;

      github.rest.issues.listLabelsOnIssue.mockResolvedValue({
        data: [{ name: 'low-risk' }],
      });

      await riskLabel({github, context, core});

      expect(github.rest.issues.removeLabel).not.toHaveBeenCalled();
      expect(github.rest.issues.addLabels).not.toHaveBeenCalled();
    });
  });
});
