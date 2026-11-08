// Policy for .github/workflows/dependabot-auto-merge.yml: reserve auto-merge
// only for Cargo security updates that stay within patch and minor versions.
// Everything else waits for a person (docs/contributing.md#dependency-updates).
// The group, directories, branch, and check names must match
// .github/dependabot.yml and the rulesets in .github/rulesets/.
const { execFileSync } = require('node:child_process');

const branch = 'develop';
const requiredChecks = ['fast checks', 'dependency checks'];
const githubActions = 15368; // integration_id of GitHub Actions status checks
const workflowLogin = 'github-actions[bot]';
const policies = {
  cargo: {
    directories: ['/tools/axum-contract', '/tools/http1-differential', '/bench/m13/axum'],
    group: 'cargo-security-compatible',
    file: /^(tools\/axum-contract|tools\/http1-differential|bench\/m13\/axum)\/Cargo\.(toml|lock)$/,
  },
};

function eligible(pr, dependencies, files, repository, metadataOK) {
  if (!metadataOK || pr.commits !== 1 || pr.state !== 'open' || pr.draft ||
      pr.user?.login !== 'dependabot[bot]' || pr.base?.ref !== branch ||
      pr.base?.repo?.full_name !== repository || pr.head?.repo?.full_name !== repository ||
      !Array.isArray(dependencies) || dependencies.length === 0 ||
      !dependencies.every(d => d && typeof d === 'object') ||
      !Array.isArray(files) || files.length === 0 || files.length !== pr.changed_files) return false;
  const policy = policies[dependencies[0].packageEcosystem];
  if (!policy) return false;
  return dependencies.every(d =>
    policies[d.packageEcosystem] === policy && policy.directories.includes(d.directory) &&
    d.dependencyGroup === policy.group &&
    ['version-update:semver-patch', 'version-update:semver-minor'].includes(d.updateType)
  ) && files.every(f => f.status === 'modified' && policy.file.test(f.filename));
}

// Auto-merge is safe only when GitHub itself waits for every required check
// from GitHub Actions on top of the latest develop.
function protectedByCI(rules) {
  const checks = rules
    .filter(r => r.type === 'required_status_checks' &&
      r.parameters?.strict_required_status_checks_policy === true)
    .flatMap(r => r.parameters.required_status_checks ?? []);
  return requiredChecks.every(name =>
    checks.some(c => c.context === name && c.integration_id === githubActions));
}

async function run({ github, context, core, merge = execFileSync }) {
  const args = { ...context.repo, pull_number: context.payload.pull_request.number };
  const repository = `${args.owner}/${args.repo}`;
  const getPR = async () => (await github.rest.pulls.get(args)).data;
  const pr = await getPR();
  if (pr.state !== 'open') return;
  // Metadata from an older event must not reserve a newer commit.
  if (pr.head.sha !== context.payload.pull_request.head.sha) {
    core.info('A newer head exists; its synchronize event will evaluate it.');
    return;
  }

  const revoke = () => revokeOwnReservation({ github, context, core });
  try {
    await evaluate();
  } catch (error) {
    // A failed evaluation must not leave an earlier reservation on a new head.
    try { await revoke(); } catch (e) { core.warning(`Cannot revoke the reservation: ${e.message}`); }
    throw error;
  }

  async function evaluate() {
    let deps;
    try { deps = JSON.parse(process.env.DEPENDENCIES || 'null'); } catch { deps = null; }
    const files = await github.paginate(github.rest.pulls.listFiles, args);
    let allowed = eligible(pr, deps, files, repository, process.env.METADATA_OK === 'true');
    if (allowed) {
      // fetch-metadata verifies only the first commit, so verify the head too.
      const commits = await github.paginate(github.rest.pulls.listCommits, args);
      allowed = commits.length === 1 && commits[0].sha === pr.head.sha &&
        commits[0].author?.login === 'dependabot[bot]' &&
        commits[0].commit?.verification?.verified === true;
    }
    if (allowed) {
      try {
        const rules = await github.request('GET /repos/{owner}/{repo}/rules/branches/{branch}',
          { ...context.repo, branch });
        const repo = (await github.rest.repos.get(context.repo)).data;
        allowed = protectedByCI(rules.data) &&
          repo.allow_auto_merge === true && repo.allow_merge_commit === true;
      } catch (error) {
        core.warning(`Cannot verify merge protection: ${error.message}`);
        allowed = false;
      }
    }
    if (!allowed) {
      await revoke();
      core.info('Not eligible, or the GitHub settings are incomplete; a person reviews this update.');
      return;
    }

    // Take in any change made while this run evaluated the pull request.
    const current = await getPR();
    if (current.head.sha !== pr.head.sha || current.base.ref !== pr.base.ref ||
        current.draft || current.commits !== 1) {
      await revoke();
      return;
    }
    // GitHub waits for the required checks; the CLI refuses if the head moved.
    merge('gh', ['pr', 'merge', String(args.pull_number), '--repo', repository,
      '--auto', '--merge', '--match-head-commit', pr.head.sha], { stdio: 'pipe' });
    core.info('Auto-merge reserved; GitHub merges once the required checks pass.');
  }
}

// Revoke only the reservation this workflow made; a person's stays.
// The workflow also calls this when the job fails or is cancelled.
async function revokeOwnReservation({ github, context, core }) {
  const pr = (await github.rest.pulls.get({ ...context.repo,
    pull_number: context.payload.pull_request.number })).data;
  if (pr.auto_merge?.enabled_by?.login === workflowLogin) {
    await github.graphql(
      'mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }',
      { id: pr.node_id });
    core.info('Disabled the auto-merge this workflow had reserved.');
  }
}

module.exports = { eligible, protectedByCI, revokeOwnReservation, run };
