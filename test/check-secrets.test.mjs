import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, beforeEach, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
// A hung child fails with a named timeout error instead of an unexplained cancellation.
const run = async (file, args, opts = {}) => {
  const options = { timeout: 30000, killSignal: 'SIGKILL', ...opts };
  try {
    return await execFileAsync(file, args, options);
  } catch (err) {
    if (err.killed) err.message = `timed out after ${options.timeout / 1000} s: ${file} ${args[0] ?? ''}`.trim();
    throw err;
  }
};
const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'check-secrets.mjs');

// Fake secrets are assembled at runtime so this file itself stays clean.
const FAKE_UDID = ['0000', '8110'].join('') + '-' + ['001A2B3C', '4D5E6F70'].join('');
const LEGACY_UDID = ['a1b2c3d4e5', 'f60718293a', '4b5c6d7e8f', '9012a3b4c5'].join('');
const CORE_DEVICE_ID = ['11111111', '2222', '3333', '4444', '555555555555'].join('-');
const PEM_KEY = ['-----BEGIN ', 'RSA PRIVATE', ' KEY-----'].join('') + '\nMIIB\n';
const PROFILE_PLIST = ['<key>', 'TeamIdentifier', '</key>\n<key>', 'ExpirationDate', '</key>\n'].join('');

const P12_ASSIGN = ['P12_PASS', 'WORD=hunter2'].join('');
let root;
let home;

const git = (...args) => run('git', args, { cwd: root });

async function put(file, content) {
  const path = join(root, file);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content);
}

async function check(mode = 'staged') {
  let stdout;
  let code = 0;
  try {
    ({ stdout } = await run('node', [SCRIPT, `--${mode}`], {
      cwd: root,
      env: { ...process.env, SIDELOAD_HOME: home },
    }));
  } catch (err) {
    ({ stdout } = err);
    code = err.code;
  }
  return { code, stdout, json: JSON.parse(stdout) };
}

async function stageAndCheck(file, content, mode = 'staged') {
  await put(file, content);
  await git('add', '-A');
  return check(mode);
}

const rules = (r) => r.json.findings.map((f) => f.rule);

describe('check-secrets', () => {
  before(async () => {
    home = await mkdtemp(join(tmpdir(), 'sideload-home-'));
  });
  after(() => rm(home, { recursive: true, force: true }));

  beforeEach(async () => {
    if (root) await rm(root, { recursive: true, force: true });
    await rm(join(home, 'config.json'), { force: true });
    root = await mkdtemp(join(tmpdir(), 'sideload-repo-'));
    await git('init', '-q', '-b', 'main');
    await git('config', 'user.name', 'dividedby');
    await git('config', 'user.email', '64715420+dividedby@users.noreply.github.com');
  });
  after(() => root && rm(root, { recursive: true, force: true }));

  it('passes a clean file', async () => {
    const r = await stageAndCheck('README.md', '# hello\n');
    assert.equal(r.code, 0);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.mode, 'staged');
    assert.equal(r.json.scanned, 1);
    assert.deepEqual(r.json.findings, []);
  });

  it('blocks a .p12 filename', async () => {
    const r = await stageAndCheck('certs/dev.P12', 'x');
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['forbidden-extension']);
  });

  it('blocks files under secrets/ and .sideload/', async () => {
    await put('secrets/notes.txt', 'hi');
    await put('.sideload/state.json', '{}');
    await git('add', '-A', '-f');
    const r = await check();
    assert.equal(r.code, 1);
    assert.deepEqual(r.json.findings.map((f) => f.file).sort(), ['.sideload/state.json', 'secrets/notes.txt']);
    assert.ok(rules(r).every((x) => x === 'forbidden-path'));
  });

  it('blocks a PEM private key with a line number', async () => {
    const r = await stageAndCheck('a.txt', 'ok\n' + PEM_KEY);
    assert.equal(r.code, 1);
    assert.equal(r.json.findings[0].rule, 'private-key');
    assert.equal(r.json.findings[0].line, 2);
  });

  it('blocks a modern UDID', async () => {
    const r = await stageAndCheck('a.txt', `device ${FAKE_UDID.toLowerCase()}\n`);
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['device-udid']);
  });

  it('blocks exact IDs saved in the sideload config (legacy UDID and CoreDevice UUID)', async () => {
    await writeFile(
      join(home, 'config.json'),
      JSON.stringify({ devices: { phone: { udid: LEGACY_UDID, coreDeviceId: CORE_DEVICE_ID } } }),
    );
    await put('a.txt', `id: ${LEGACY_UDID}\n`);
    await put('b.txt', `id: ${CORE_DEVICE_ID.toUpperCase()}\n`);
    await git('add', '-A');
    const r = await check();
    assert.equal(r.code, 1);
    assert.deepEqual(r.json.findings.map((f) => [f.file, f.rule]), [
      ['a.txt', 'saved-device-id'],
      ['b.txt', 'saved-device-id'],
    ]);
  });

  it('does not block a git-SHA-like 40-hex string that is not in the config', async () => {
    await writeFile(join(home, 'config.json'), JSON.stringify({ devices: { phone: { udid: LEGACY_UDID } } }));
    const r = await stageAndCheck('a.txt', `commit ${'0123456789abcdef'.repeat(3).slice(0, 40)}\n`);
    assert.equal(r.code, 0);
  });

  it('exits 2 with JSON when the config is not valid JSON', async () => {
    await writeFile(join(home, 'config.json'), `{ nope ${LEGACY_UDID}`);
    const r = await stageAndCheck('a.txt', 'x\n');
    assert.equal(r.code, 2);
    assert.equal(r.json.ok, false);
    assert.ok(!r.stdout.includes(LEGACY_UDID));
  });

  it('blocks provisioning profile markers, including in binary files', async () => {
    const text = await stageAndCheck('p.txt', PROFILE_PLIST);
    assert.deepEqual(rules(text), ['provisioning-profile']);
    const bin = await stageAndCheck('p.bin', Buffer.concat([Buffer.from([0x30, 0x82, 0x00, 0x00]), Buffer.from(PROFILE_PLIST)]));
    assert.ok(rules(bin).includes('provisioning-profile'));
    assert.ok(bin.json.findings.some((f) => f.file === 'p.bin'));
  });

  it('blocks an obvious p12 password assignment', async () => {
    const r = await stageAndCheck('a.sh', P12_ASSIGN + '\n');
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['p12-password']);
    const prose = await stageAndCheck('b.md', 'set the p12 password in the keychain\n');
    assert.ok(!prose.json.findings.some((f) => f.file === 'b.md'));
  });

  it('skips lines containing the allowlist marker', async () => {
    const r = await stageAndCheck('a.txt', `${FAKE_UDID} # sideload-allow-secret\nclean\n`);
    assert.equal(r.code, 0);
    const second = await stageAndCheck('b.txt', `${FAKE_UDID}\n`);
    assert.equal(second.code, 1);
  });

  it('flags oversize files', async () => {
    const r = await stageAndCheck('big.txt', Buffer.alloc(5 * 1024 * 1024 + 1, 'a'));
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['oversize']);
  });

  it('never echoes secret values in output', async () => {
    await writeFile(join(home, 'config.json'), JSON.stringify({ devices: { phone: { udid: LEGACY_UDID } } }));
    await put('a.txt', `${FAKE_UDID}\n${LEGACY_UDID}\n${PEM_KEY}${P12_ASSIGN}\n`);
    await git('add', '-A');
    const r = await check();
    assert.equal(r.code, 1);
    assert.ok(r.json.findings.length >= 4);
    for (const secret of [FAKE_UDID, LEGACY_UDID, 'hunter2', 'MIIB']) {
      assert.ok(!r.stdout.includes(secret), 'output leaked a secret value');
    }
    assert.equal(r.stdout.trim().split('\n').length, 1);
  });

  it('--all scans tracked and untracked-not-ignored files from the working tree', async () => {
    await put('.gitignore', 'ignored.txt\n');
    await put('tracked.txt', 'clean\n');
    await git('add', '.gitignore', 'tracked.txt');
    await put('tracked.txt', `${FAKE_UDID}\n`); // unstaged edit: only --all sees it
    await put('untracked.txt', 'clean\n');
    await put('ignored.txt', `${FAKE_UDID}\n`);
    const staged = await check('staged');
    assert.equal(staged.code, 0);
    const all = await check('all');
    assert.equal(all.code, 1);
    assert.equal(all.json.mode, 'all');
    assert.deepEqual(all.json.findings.map((f) => f.file), ['tracked.txt']);
    assert.equal(all.json.scanned, 3);
  });

  it('scans files whose type changed (symlink to regular file)', async () => {
    await symlink('target', join(root, 'link'));
    await git('add', '-A');
    await git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'symlink');
    await unlink(join(root, 'link'));
    const r = await stageAndCheck('link', `${PEM_KEY}${FAKE_UDID}\n`);
    assert.equal((await git('diff', '--cached', '--name-status')).stdout.trim(), 'T\tlink');
    assert.equal(r.code, 1);
    assert.equal(r.json.scanned, 1);
    assert.deepEqual(rules(r), ['private-key', 'device-udid']);
  });

  it('matches forbidden paths and env files case-insensitively', async () => {
    await put('Secrets/a.txt', 'x');
    await put('X.APP/b', 'x');
    await put('Y.XCArchive/c', 'x');
    await put('.ENV', 'x');
    await put('.Env.local', 'x');
    await git('add', '-A');
    const r = await check();
    assert.equal(r.code, 1);
    assert.deepEqual(
      r.json.findings.map((f) => `${f.file}:${f.rule}`).sort(),
      [
        '.ENV:forbidden-filename',
        '.Env.local:forbidden-filename',
        'Secrets/a.txt:forbidden-path',
        'X.APP/b:forbidden-path',
        'Y.XCArchive/c:forbidden-path',
      ],
    );
  });

  it('scans UTF-16 and other NUL-containing files for text rules', async () => {
    const utf16 = (str) => Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(str, 'utf16le')]);
    const udid = await stageAndCheck('u16.txt', utf16(`id ${FAKE_UDID}\n`));
    assert.equal(udid.code, 1);
    assert.deepEqual(rules(udid), ['device-udid']);
    const pem = await stageAndCheck('k16.txt', utf16(PEM_KEY));
    assert.ok(rules(pem).includes('private-key'));
    assert.ok(!pem.stdout.includes(FAKE_UDID));
  });

  it('checks paths for UDIDs and saved IDs, and redacts them in findings', async () => {
    await writeFile(join(home, 'config.json'), JSON.stringify({ devices: { phone: { udid: LEGACY_UDID } } }));
    await put(`d/${FAKE_UDID}.json`, 'x');
    await put(`d/${LEGACY_UDID}.txt`, 'x');
    await put(`d/${FAKE_UDID}.P12`, 'x');
    await git('add', '-A');
    const r = await check();
    assert.equal(r.code, 1);
    const byRule = (rule) => r.json.findings.filter((f) => f.rule === rule).length;
    assert.equal(byRule('device-udid'), 2);
    assert.equal(byRule('saved-device-id'), 1);
    assert.equal(byRule('forbidden-extension'), 1);
    for (const secret of [FAKE_UDID, FAKE_UDID.toLowerCase(), LEGACY_UDID]) {
      assert.ok(!r.stdout.includes(secret), 'output leaked an ID from a path');
    }
    assert.ok(r.json.findings.every((f) => f.file.includes('...')));
  });

  it('matches UDIDs adjacent to word characters or extra hex', async () => {
    const prefixed = await stageAndCheck('a.txt', `DEVICE_${FAKE_UDID}\n`);
    assert.deepEqual(rules(prefixed), ['device-udid']);
    const suffixed = await stageAndCheck('b.txt', `${FAKE_UDID}abc\n`);
    assert.ok(suffixed.json.findings.some((f) => f.file === 'b.txt' && f.rule === 'device-udid'));
  });

  it('matches JSON-style p12 password keys', async () => {
    const r = await stageAndCheck('a.json', `{"p12${'Pass'}word":"x"}\n`);
    assert.deepEqual(rules(r), ['p12-password']);
  });

  it('blocks files named exactly like a forbidden extension', async () => {
    await put('.p12', 'x');
    await put('sub/.KEY', 'x');
    await put('.pem', 'x');
    await git('add', '-A');
    const r = await check();
    assert.deepEqual(r.json.findings.map((f) => `${f.file}:${f.rule}`).sort(), [
      '.p12:forbidden-extension',
      '.pem:forbidden-extension',
      'sub/.KEY:forbidden-extension',
    ]);
  });

  it('detects binary content past the first 8000 bytes', async () => {
    const r = await stageAndCheck(
      'late.bin',
      Buffer.concat([Buffer.alloc(9000, 'a'), Buffer.from(`${FAKE_UDID}\n`, 'utf16le')]),
    );
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['device-udid']);
  });

  it('reads a staged path containing a colon as its own blob', async () => {
    await put('t.txt', 'clean\n');
    await git('add', '-A');
    await git('commit', '-q', '-m', 'base', '--no-verify');
    const r = await stageAndCheck('0:t.txt', `${FAKE_UDID}\n`);
    assert.equal(r.code, 1);
    assert.deepEqual(rules(r), ['device-udid']);
    assert.ok(!r.stdout.includes(FAKE_UDID));
  });

  it('catches p12 password variants and security -P, not calls', async () => {
    const lines = [
      ['P12_', 'PASS=abc123'].join(''),
      ['P12_', 'PASSPHRASE=abc123'].join(''),
      ['p12 ', 'password: abc123'].join(''),
      ['security import dev.p12 ', '-P abc123'].join(''),
      ['PGP: -----BEGIN PGP ', 'PRIVATE KEY BLOCK-----'].join(''),
      ['security import dev.p12 -k login.keychain ', '-P "pw1" -T /usr/bin/codesign'].join(''),
      ['security export -t identities ', "-P 'pw1'"].join(''),
      ['{"p12', 'Password":"two words"}'].join(''),
    ];
    for (const line of lines) {
      const r = await stageAndCheck('a.txt', `${line}\n`);
      assert.equal(r.code, 1, line.slice(0, 12));
    }
    await git('rm', '-q', '--cached', 'a.txt');
    await unlink(join(root, 'a.txt'));
    const ok = await stageAndCheck('b.mjs', [
      "const p12", "Password = await getPw();\nrun(['export', '-P', pw]);\n",
      "x = { p12", "Password: opts.password };\n",
      "security import dev.p12 ", '-P "$PW"\n',
      "P12_", 'PASS="$PW"\n',
    ].join(''));
    assert.equal(ok.code, 0);
  });

  it('skips submodule gitlinks instead of erroring', async () => {
    await git('update-index', '--add', '--cacheinfo', `160000,${'a'.repeat(40)},sub`);
    const r = await check();
    assert.equal(r.code, 0, r.stdout);
    assert.equal(r.json.ok, true);
  });

  it('exits 2 with JSON on bad usage', async () => {
    let out;
    let code = 0;
    try {
      await run('node', [SCRIPT], { cwd: root });
    } catch (err) {
      out = err.stdout;
      code = err.code;
    }
    assert.equal(code, 2);
    assert.equal(JSON.parse(out).ok, false);
  });
});
