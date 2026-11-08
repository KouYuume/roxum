// Tests for dependabot-auto-merge.cjs; dependency-checks.yml runs them.
//   node --test .github/scripts/dependabot-auto-merge.test.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { eligible, protectedByCI, run } = require('./dependabot-auto-merge.cjs');

const repository = 'example-org/roxum';

function fixture() {
  return {
    pr: { state: 'open', draft: false, user: { login: 'dependabot[bot]' },
      base: { ref: 'develop', repo: { full_name: repository } },
      head: { sha: 'abc', repo: { full_name: repository } },
      changed_files: 1, commits: 1, node_id: 'PR_id' },
    deps: [{ packageEcosystem: 'cargo', directory: '/tools/axum-contract',
      dependencyGroup: 'cargo-security-compatible',
      updateType: 'version-update:semver-patch' }],
    files: [{ filename: 'tools/axum-contract/Cargo.lock', status: 'modified' }],
  };
}

function check(f, metadataOK = true) {
  return eligible(f.pr, f.deps, f.files, repository, metadataOK);
}

const rules = [{ type: 'required_status_checks', parameters: {
  strict_required_status_checks_policy: true,
  required_status_checks: [
    { context: 'fast checks', integration_id: 15368 },
    { context: 'dependency checks', integration_id: 15368 },
  ],
} }];

for (const level of ['patch', 'minor']) {
  test(`accepts a Cargo security ${level} update`, () => {
    const f = fixture();
    f.deps[0].updateType = `version-update:semver-${level}`;
    assert.equal(check(f), true);
  });
}

for (const directory of ['/tools/axum-contract', '/tools/http1-differential', '/bench/m13/axum']) {
  for (const name of ['Cargo.toml', 'Cargo.lock']) {
    test(`accepts ${directory.slice(1)}/${name}`, () => {
      const f = fixture();
      f.deps[0].directory = directory;
      f.files[0].filename = `${directory.slice(1)}/${name}`;
      assert.equal(check(f), true);
    });
  }
}

test('accepts one update across two of the Cargo projects', () => {
  const f = fixture();
  f.deps.push({ ...f.deps[0], directory: '/bench/m13/axum' });
  f.files.push({ filename: 'bench/m13/axum/Cargo.lock', status: 'modified' });
  f.pr.changed_files = 2;
  assert.equal(check(f), true);
});

const rejections = {
  'additional human commit': f => { f.pr.commits = 2; },
  'missing commit count': f => { delete f.pr.commits; },
  'normal update': f => { f.deps[0].dependencyGroup = ''; },
  'normal update group': f => { f.deps[0].dependencyGroup = 'cargo-minor-and-patch'; },
  'major update': f => { f.deps[0].updateType = 'version-update:semver-major'; },
  'major in group': f => { f.deps.push({ ...f.deps[0], updateType: 'version-update:semver-major' }); },
  'unknown version': f => { f.deps[0].updateType = 'unknown'; },
  'GitHub Actions update': f => {
    f.deps[0].packageEcosystem = 'github_actions'; f.deps[0].directory = '/';
    f.deps[0].dependencyGroup = 'actions-security-compatible';
    f.files[0].filename = '.github/workflows/ci.yml';
  },
  'Docker update': f => {
    f.deps[0].packageEcosystem = 'docker'; f.deps[0].directory = '/tools/linux';
    f.deps[0].dependencyGroup = 'docker-security-compatible';
    f.files[0].filename = 'tools/linux/Dockerfile';
  },
  'other directory': f => { f.deps[0].directory = '/'; },
  'different author': f => { f.pr.user.login = 'someone'; },
  'fork': f => { f.pr.head.repo.full_name = 'someone/fork'; },
  'main as base': f => { f.pr.base.ref = 'main'; },
  'draft': f => { f.pr.draft = true; },
  'closed': f => { f.pr.state = 'closed'; },
  'root Cargo.lock': f => { f.files[0].filename = 'Cargo.lock'; },
  'source edit': f => { f.files[0].filename = 'tools/axum-contract/src/main.rs'; },
  'workflow edit': f => { f.files[0].filename = '.github/workflows/ci.yml'; },
  'policy edit': f => { f.files[0].filename = '.github/scripts/dependabot-auto-merge.cjs'; },
  'added file': f => { f.files[0].status = 'added'; },
  'renamed file': f => { f.files[0].status = 'renamed'; },
  'missing files': f => { f.pr.changed_files = 2; },
  'malformed metadata entry': f => { f.deps = [null]; },
  'mixed ecosystems': f => { f.deps.push({ ...f.deps[0], packageEcosystem: 'github_actions' }); },
  'empty metadata': f => { f.deps = []; },
  'missing metadata': f => { f.deps = null; },
};
for (const [name, mutate] of Object.entries(rejections)) {
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.equal(check(f), false);
  });
}

test('rejects failed metadata or signature verification', () => {
  assert.equal(check(fixture(), false), false);
});

test('requires both checks from GitHub Actions on an up-to-date branch', () => {
  assert.equal(protectedByCI(rules), true);
  assert.equal(protectedByCI([]), false);
  const changes = [
    r => { r[0].parameters.strict_required_status_checks_policy = false; },
    r => { r[0].parameters.required_status_checks[1].integration_id = null; },
    r => { r[0].parameters.required_status_checks[1].context = 'other'; },
    r => { r[0].parameters.required_status_checks.shift(); },
  ];
  for (const change of changes) {
    const r = structuredClone(rules);
    change(r);
    assert.equal(protectedByCI(r), false);
  }
});

async function exercise({ eligibleUpdate = true, metadataOK = true, protectedBranch = true,
  autoMerge = true, mergeCommit = true, changedHead = false, race = false,
  commitAuthor = 'dependabot[bot]', verified = true, commitSha = 'abc',
  reservationOwner = 'github-actions[bot]', failFiles = false } = {}) {
  const f = fixture();
  if (!eligibleUpdate) f.deps[0].dependencyGroup = '';
  f.pr.auto_merge = reservationOwner ? { enabled_by: { login: reservationOwner } } : null;
  const calls = [];
  let reads = 0;
  const github = {
    rest: {
      pulls: {
        get: async () => {
          reads++;
          const pr = structuredClone(f.pr);
          if (changedHead || (race && reads > 1)) pr.head.sha = 'new';
          return { data: pr };
        },
        listFiles: 'files',
        listCommits: 'commits',
      },
      repos: { get: async () => ({ data: {
        allow_auto_merge: autoMerge, allow_merge_commit: mergeCommit } }) },
    },
    paginate: async method => {
      if (method === 'files' && failFiles) throw new Error('502 Bad Gateway');
      return method === 'files' ? f.files : [{
        sha: commitSha, author: { login: commitAuthor }, commit: { verification: { verified } },
      }];
    },
    request: async () => ({ data: protectedBranch ? rules : [] }),
    graphql: async () => calls.push(['disable']),
  };
  process.env.METADATA_OK = String(metadataOK);
  process.env.DEPENDENCIES = JSON.stringify(f.deps);
  try {
    await run({ github,
      context: { repo: { owner: 'example-org', repo: 'roxum' },
        payload: { pull_request: { number: 1, head: { sha: 'abc' } } } },
      core: { info() {}, warning() {} },
      merge: (...args) => calls.push(['merge', ...args]) });
  } catch (error) {
    error.calls = calls;
    throw error;
  }
  return calls;
}

test('reserves a merge commit for the exact head', async () => {
  const calls = await exercise({ reservationOwner: null });
  assert.deepEqual(calls.map(c => c[0]), ['merge']);
  assert.equal(calls[0][1], 'gh');
  const args = calls[0][2];
  assert.ok(args.includes('--auto') && args.includes('--merge'));
  assert.ok(!args.includes('--squash'));
  assert.deepEqual(args.slice(-2), ['--match-head-commit', 'abc']);
});

for (const opts of [{ eligibleUpdate: false }, { metadataOK: false }, { protectedBranch: false },
  { autoMerge: false }, { mergeCommit: false }, { race: true }]) {
  test(`revokes its own reservation: ${JSON.stringify(opts)}`, async () => {
    assert.deepEqual((await exercise(opts)).map(c => c[0]), ['disable']);
  });
}

for (const opts of [{ commitAuthor: 'human' }, { verified: false }, { commitSha: 'different' }]) {
  test(`rejects an untrusted head commit: ${JSON.stringify(opts)}`, async () => {
    assert.deepEqual((await exercise(opts)).map(c => c[0]), ['disable']);
  });
}

test('a stale event neither reserves nor revokes', async () => {
  assert.deepEqual(await exercise({ changedHead: true }), []);
});

test("keeps a person's reservation", async () => {
  assert.deepEqual(await exercise({ eligibleUpdate: false, reservationOwner: 'KouYuume' }), []);
});

test('does nothing for an ineligible update without a reservation', async () => {
  assert.deepEqual(await exercise({ eligibleUpdate: false, reservationOwner: null }), []);
});

test('revokes its own reservation when the evaluation fails, then fails', async () => {
  const error = await exercise({ failFiles: true }).then(() => null, e => e);
  assert.match(error?.message ?? '', /502/);
  assert.deepEqual(error.calls.map(c => c[0]), ['disable']);
});
