import assert from 'node:assert/strict';
import { test } from '@jest/globals';
import { readFileSync } from 'node:fs';
import authorize from '../.github/actions/authorize-development-deployment/authorize.cjs';

const sha = 'e307b68ab682e6caa4dfcde76b62db8d7771313d';

function fixture() {
  const outputs = {};
  const calls = [];
  const policyCalls = [];
  const policy = JSON.parse(readFileSync(new URL('../.github/approved-fork-deployers.json', import.meta.url), 'utf8'));
  const input = {
    context: {
      repo: { owner: 'trade-tariff', repo: 'trade-tariff-frontend' },
      eventName: 'pull_request_target',
      ref: 'refs/heads/main',
      sha: 'a'.repeat(40),
      actor: 'fasjkn',
      payload: {
        repository: { default_branch: 'main' },
        pull_request: {
          user: { login: 'fasjkn' },
          base: { ref: 'main', repo: { full_name: 'trade-tariff/trade-tariff-frontend' } },
          head: { sha, repo: { full_name: 'fasjkn/trade-tariff-frontend', owner: { login: 'fasjkn' } } },
        },
      },
    },
    triggeringActor: 'fasjkn',
    core: {
      setOutput: (key, value) => { outputs[key] = value; },
      info: () => {},
    },
    github: {
      rest: {
        repos: {
          getContent: async request => {
            policyCalls.push(request);
            return { data: { content: Buffer.from(JSON.stringify(policy)).toString('base64') } };
          },
          getCollaboratorPermissionLevel: async ({ username }) => {
            calls.push(['permission', username]);
            return { data: { permission: username === 'willfish' ? 'write' : 'read' } };
          },
          getCommit: async ({ ref }) => {
            calls.push(['commit', ref]);
            return { data: { sha } };
          },
        },
      },
    },
  };
  return { input, outputs, calls, policy, policyCalls };
}

test('Gabriel can deploy his fork commit without repository write access', async () => {
  const { input, outputs, calls } = fixture();
  await authorize(input);
  assert.deepEqual(outputs, { sha });
  assert.deepEqual(calls, []);
});

test('removing an account from the list denies its next authorization', async () => {
  const { input, outputs, policy } = fixture();
  policy['trade-tariff-frontend'] = [];
  await assert.rejects(authorize(input), /fork must belong to an approved/);
  assert.deepEqual(outputs, {});
});

test('policy is read only from tools main, not the caller or PR', async () => {
  const { input, policyCalls } = fixture();
  await authorize(input);
  assert.deepEqual(policyCalls, [{
    owner: 'trade-tariff',
    repo: 'trade-tariff-tools',
    path: '.github/approved-fork-deployers.json',
    ref: 'main',
  }]);
});

test('Gabriel is also approved for backend fork code', async () => {
  const { input, outputs } = fixture();
  input.context.repo.repo = 'trade-tariff-backend';
  input.context.payload.pull_request.base.repo.full_name = 'trade-tariff/trade-tariff-backend';
  input.context.payload.pull_request.head.repo.full_name = 'fasjkn/trade-tariff-backend';
  await authorize(input);
  assert.equal(outputs.sha, sha);
});

test('a repository without an external account entry denies Gabriel', async () => {
  const { input, outputs } = fixture();
  input.context.repo.repo = 'trade-tariff-admin';
  input.context.payload.pull_request.base.repo.full_name = 'trade-tariff/trade-tariff-admin';
  input.context.payload.pull_request.head.repo.full_name = 'fasjkn/trade-tariff-admin';
  await assert.rejects(authorize(input), /fork must belong to an approved/);
  assert.deepEqual(outputs, {});
});

test('frontend approval does not grant backend approval when its account entry is removed', async () => {
  const { input, outputs, policy } = fixture();
  policy['trade-tariff-backend'] = [];
  input.context.repo.repo = 'trade-tariff-backend';
  input.context.payload.pull_request.base.repo.full_name = 'trade-tariff/trade-tariff-backend';
  input.context.payload.pull_request.head.repo.full_name = 'fasjkn/trade-tariff-backend';
  await assert.rejects(authorize(input), /fork must belong to an approved/);
  assert.deepEqual(outputs, {});
});

test('a repository with the same name in another organisation cannot use the policy', async () => {
  const { input, outputs, policyCalls } = fixture();
  input.context.repo.owner = 'another-organisation';
  await assert.rejects(authorize(input), /restricted to the trade-tariff organisation/);
  assert.deepEqual(outputs, {});
  assert.deepEqual(policyCalls, []);
});

test('an unavailable central policy fails closed', async () => {
  const { input, outputs } = fixture();
  input.github.rest.repos.getContent = async () => {
    throw Object.assign(new Error('Policy unavailable'), { status: 503 });
  };
  await assert.rejects(authorize(input), /Policy unavailable/);
  assert.deepEqual(outputs, {});
});

test('a repository writer can label and rerun Gabriel’s fork deployment', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'willfish';
  input.triggeringActor = 'willfish';
  await authorize(input);
  assert.equal(outputs.sha, sha);
});

test('an unlisted fork author is denied even when a writer triggers deployment', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'willfish';
  input.triggeringActor = 'willfish';
  input.context.payload.pull_request.user.login = 'unlisted';
  await assert.rejects(authorize(input), /fork must belong to an approved/);
  assert.deepEqual(outputs, {});
});

test('an approved author cannot deploy another account’s fork', async () => {
  const { input, outputs } = fixture();
  input.context.payload.pull_request.head.repo.owner.login = 'unlisted';
  await assert.rejects(authorize(input), /fork must belong to an approved/);
  assert.deepEqual(outputs, {});
});

test('an unapproved triggering account cannot deploy Gabriel’s fork', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'unlisted';
  input.triggeringActor = 'unlisted';
  await assert.rejects(authorize(input), /Account unlisted cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('an unapproved account cannot rerun an approved deployment', async () => {
  const { input, outputs } = fixture();
  input.triggeringActor = 'unlisted';
  await assert.rejects(authorize(input), /Account unlisted cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('a writer’s rerun cannot approve an originally unapproved account', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'unlisted';
  input.triggeringActor = 'willfish';
  await assert.rejects(authorize(input), /Account unlisted cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('repository writers retain same-repository PR deployment', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'willfish';
  input.triggeringActor = 'willfish';
  input.context.payload.pull_request.head.repo.full_name = 'trade-tariff/trade-tariff-frontend';
  await authorize(input);
  assert.equal(outputs.sha, sha);
});

test('manual deployment resolves a ref to an immutable commit', async () => {
  const { input, outputs, calls } = fixture();
  input.context.eventName = 'workflow_dispatch';
  input.context.actor = 'willfish';
  input.triggeringActor = 'willfish';
  input.context.payload.inputs = { sha: 'refs/pull/3457/head' };
  delete input.context.payload.pull_request;
  await authorize(input);
  assert.equal(outputs.sha, sha);
  assert.deepEqual(calls.at(-1), ['commit', 'refs/pull/3457/head']);
});

test('manual deployment without a ref resolves the workflow commit', async () => {
  const { input, calls } = fixture();
  input.context.eventName = 'workflow_dispatch';
  input.context.actor = 'willfish';
  input.triggeringActor = 'willfish';
  delete input.context.payload.pull_request;
  await authorize(input);
  assert.deepEqual(calls.at(-1), ['commit', input.context.sha]);
});

test('the fork allowlist does not give read-only users manual dispatch privileges', async () => {
  const { input, outputs } = fixture();
  input.context.eventName = 'workflow_dispatch';
  await assert.rejects(authorize(input), /Account fasjkn cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('authorization refuses code or an allowlist from a non-default branch', async () => {
  const { input, outputs } = fixture();
  input.context.ref = 'refs/heads/untrusted';
  await assert.rejects(authorize(input), /must run from the default branch/);
  assert.deepEqual(outputs, {});
});

test('the original restricted pull_request event cannot authorize deployment', async () => {
  const { input, outputs } = fixture();
  input.context.eventName = 'pull_request';
  await assert.rejects(authorize(input), /event cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('a PR targeting another branch cannot authorize deployment', async () => {
  const { input, outputs } = fixture();
  input.context.payload.pull_request.base.ref = 'untrusted';
  await assert.rejects(authorize(input), /must target this repository/);
  assert.deepEqual(outputs, {});
});

test('permission API failures fail closed', async () => {
  const { input, outputs } = fixture();
  input.context.actor = 'willfish';
  input.github.rest.repos.getCollaboratorPermissionLevel = async () => {
    throw Object.assign(new Error('Unavailable'), { status: 503 });
  };
  await assert.rejects(authorize(input), /Unavailable/);
  assert.deepEqual(outputs, {});
});

test('unknown accounts fail closed', async () => {
  const { input, outputs } = fixture();
  input.triggeringActor = 'unknown';
  input.github.rest.repos.getCollaboratorPermissionLevel = async () => {
    throw Object.assign(new Error('Not found'), { status: 404 });
  };
  await assert.rejects(authorize(input), /Account unknown cannot authorize/);
  assert.deepEqual(outputs, {});
});

test('only a full commit SHA reaches privileged jobs', async () => {
  const { input, outputs } = fixture();
  input.context.payload.pull_request.head.sha = 'main';
  await assert.rejects(authorize(input), /requires a full commit SHA/);
  assert.deepEqual(outputs, {});
});
