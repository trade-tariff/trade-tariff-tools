module.exports = async ({ github, context, core, triggeringActor }) => {
  if (context.repo.owner !== 'trade-tariff') {
    throw new Error('Deployment authorization is restricted to the trade-tariff organisation.');
  }

  const repository = `${context.repo.owner}/${context.repo.repo}`;
  const defaultRef = `refs/heads/${context.payload.repository.default_branch}`;

  if (context.ref !== defaultRef) {
    throw new Error('Deployment authorization must run from the default branch.');
  }

  if (!['pull_request_target', 'workflow_dispatch'].includes(context.eventName)) {
    throw new Error('This event cannot authorize a deployment.');
  }

  const { data } = await github.rest.repos.getContent({
    owner: 'trade-tariff',
    repo: 'trade-tariff-tools',
    path: '.github/approved-fork-deployers.json',
    ref: 'main',
  });
  const policy = JSON.parse(Buffer.from(data.content, 'base64').toString('utf8'));
  const approved = new Set((policy[context.repo.repo] || []).map(login => login.toLowerCase()));

  const hasWriteAccess = async login => {
    try {
      const { data } = await github.rest.repos.getCollaboratorPermissionLevel({
        ...context.repo,
        username: login,
      });
      return ['write', 'maintain', 'admin'].includes(data.permission);
    } catch (error) {
      if (error.status === 404) return false;
      throw error;
    }
  };

  const pr = context.payload.pull_request;
  if (context.eventName === 'pull_request_target') {
    if (pr.base.repo.full_name !== repository || pr.base.ref !== context.payload.repository.default_branch) {
      throw new Error('The pull request must target this repository and its default branch.');
    }

    if (pr.head.repo.full_name !== repository && (
      !approved.has(pr.user.login.toLowerCase()) ||
      pr.head.repo.owner.login.toLowerCase() !== pr.user.login.toLowerCase()
    )) {
      throw new Error('The fork must belong to an approved deployment account.');
    }
  }

  for (const login of new Set([context.actor, triggeringActor])) {
    if (!login || !(
      (context.eventName === 'pull_request_target' && approved.has(login.toLowerCase())) ||
      await hasWriteAccess(login)
    )) {
      throw new Error(`Account ${login || '(missing)'} cannot authorize this deployment.`);
    }
  }

  let sha = pr?.head.sha;
  if (context.eventName === 'workflow_dispatch') {
    const { data } = await github.rest.repos.getCommit({
      ...context.repo,
      ref: context.payload.inputs?.sha || context.sha,
    });
    sha = data.sha;
  }

  if (!/^[a-f0-9]{40}$/.test(sha || '')) {
    throw new Error('Deployment requires a full commit SHA.');
  }

  core.setOutput('sha', sha);
  core.info(`Authorized development deployment of ${sha}.`);
};
