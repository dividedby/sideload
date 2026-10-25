#!/usr/bin/env node
// Secrets guard. Blocks key material, provisioning profiles, device IDs and
// obvious password assignments from entering the repo.
//
//   node scripts/check-secrets.mjs --staged   files in the index (pre-commit)
//   node scripts/check-secrets.mjs --all      tracked + untracked-not-ignored files (CI)
//
// Prints exactly one JSON object to stdout: { ok, mode, scanned, findings }.
// Findings never echo the matched value. Exit 0 clean, 1 findings, 2 internal error.
//
// Allowlist: a line containing `sideload-allow-secret` is skipped by all content rules.
// Test fixtures should build fake secrets at runtime instead of using the allowlist.

import { execFile } from 'node:child_process';
import { lstat, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, extname, join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
// Every child gets a timeout so a hung process fails loudly instead of stalling the hook.
const run = async (file, args, opts = {}) => {
  const options = { timeout: 30000, killSignal: 'SIGKILL', ...opts };
  try {
    return await execFileAsync(file, args, options);
  } catch (err) {
    if (err.killed) err.message = `timed out after ${options.timeout / 1000} s: ${file} ${args[0] ?? ''}`.trim();
    throw err;
  }
};

const MAX_BYTES = 5 * 1024 * 1024;
const ALLOW_MARKER = 'sideload-allow-secret';

const FORBIDDEN_EXTENSIONS = new Set([
  '.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.ipa',
  '.key', '.pem', '.cer', '.der', '.certsigningrequest',
]);
const FORBIDDEN_SEGMENTS = new Set(['.sideload', 'secrets', 'xcuserdata', 'deriveddata']);
const FORBIDDEN_SEGMENT_SUFFIXES = ['.app', '.xcarchive', '.dsym'];

const PEM_KEY = /-----BEGIN (?:[A-Z ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----/;
// No \b or hex boundaries: adjacent word chars or extra hex must not hide a UDID.
const MODERN_UDID = /0000[0-9a-f]{4}-[0-9a-f]{16}/i;
// A literal value: a quoted string that is not a `$VAR`/`${...}` reference, or a bare
// token that is not a variable, member access, call, await or env read. So
// `p12Password = await getPw()` / `opts.password` pass but a literal does not.
const LITERAL = String.raw`(?:(["'\x60])(?!\$)(?:(?!\1).)+\1|(?!await\b|new\b|process\.|\$|[A-Za-z_][\w$]*\.[A-Za-z_$])(?=([^\s"'\x60(,;)]+))\2(?![\w.$]*\())`;
const P12_PASS_RE = new RegExp(String.raw`p12[ _-]?pass(?:word|phrase)?["']?\s*[:=]\s*` + LITERAL, 'i');
// A literal passed to the -P flag of the keychain `security` import/export tool.
// Two steps instead of a leading `.*`, so repeated `security import` stays linear.
const SECURITY_CMD_RE = /\bsecurity\s+(?:import|export)\b/;
const SECURITY_P_RE = new RegExp(String.raw`\s-P\s+` + LITERAL);
const securityPassword = (line) => {
  const m = SECURITY_CMD_RE.exec(line);
  return m !== null && SECURITY_P_RE.test(line.slice(m.index + m[0].length));
};
// Built at runtime so this file does not contain the literal markers.
const PROFILE_DEVICES = '<key>' + 'ProvisionedDevices' + '</key>';
const PROFILE_TEAM = '<key>' + 'TeamIdentifier' + '</key>';
const PROFILE_EXPIRY = '<key>' + 'ExpirationDate' + '</key>';

function parseMode(argv) {
  const modes = argv.filter((a) => a === '--staged' || a === '--all');
  if (argv.length !== 1 || modes.length !== 1) {
    throw new Error('usage: check-secrets.mjs --staged | --all');
  }
  return modes[0].slice(2);
}

async function git(root, args, opts = {}) {
  const { stdout } = await run('git', args, {
    cwd: root,
    encoding: opts.buffer ? 'buffer' : 'utf8',
    maxBuffer: MAX_BYTES + 1024 * 1024,
  });
  return stdout;
}

const splitZ = (s) => s.split('\0').filter(Boolean);

async function loadSavedDeviceIds() {
  const home = process.env.SIDELOAD_HOME || join(homedir(), '.sideload');
  let raw;
  try {
    raw = await readFile(join(home, 'config.json'), 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
  // Unparseable config means the exact-match check cannot run: fail loudly (exit 2).
  // Parse errors can quote the input, so replace the message.
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('sideload config.json is not valid JSON; cannot check saved device IDs');
  }
  const devices = parsed?.devices ?? {};
  const ids = [];
  for (const dev of Object.values(devices)) {
    for (const id of [dev?.udid, dev?.coreDeviceId]) {
      if (typeof id === 'string' && id.length >= 8) ids.push(id.toLowerCase());
    }
  }
  return ids;
}

function checkPath(file, savedIds) {
  const out = [];
  const segments = file.toLowerCase().split('/');
  const name = basename(file).toLowerCase();
  // A bare dotfile like `.p12` has no extname, so compare the whole name too.
  if (FORBIDDEN_EXTENSIONS.has(extname(name)) || FORBIDDEN_EXTENSIONS.has(name)) {
    out.push({ file, rule: 'forbidden-extension', message: 'file type is reserved for secrets and must not be committed' });
  }
  if (name.startsWith('.env')) {
    out.push({ file, rule: 'forbidden-filename', message: 'env files must not be committed' });
  }
  const dirs = segments.slice(0, -1);
  if (dirs.some((s) => FORBIDDEN_SEGMENTS.has(s) || FORBIDDEN_SEGMENT_SUFFIXES.some((x) => s.endsWith(x)))) {
    out.push({ file, rule: 'forbidden-path', message: 'path is inside a secrets/build directory' });
  }
  const lower = file.toLowerCase();
  if (MODERN_UDID.test(file)) {
    out.push({ file, rule: 'device-udid', message: 'path contains something that looks like an Apple device UDID' });
  }
  if (savedIds.some((id) => lower.includes(id))) {
    out.push({ file, rule: 'saved-device-id', message: 'path contains a device ID saved in the sideload config' });
  }
  return out;
}

// Findings must never echo device IDs, even inside file paths: keep the last 4 chars.
function redactPath(file, savedIds) {
  const mask = (m) => `...${m.slice(-4)}`;
  let out = file.replace(new RegExp(MODERN_UDID.source, 'gi'), mask);
  for (const id of savedIds) {
    out = out.replace(new RegExp(id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), mask);
  }
  return out;
}

const isBinary = (buf) => buf.includes(0);

function checkContent(file, buf, savedIds) {
  const out = [];
  const binary = isBinary(buf);
  // Binary/UTF-16 content is scanned as a NUL-stripped latin1 view so ASCII
  // secrets inside UTF-16 or embedded blobs are still seen. Line numbers are
  // only meaningful for real text files.
  const text = binary ? buf.toString('latin1').replace(/\0/g, '') : buf.toString('utf8');
  // Drop allowlisted lines but keep line numbering.
  const lines = text.split('\n').map((l) => (l.includes(ALLOW_MARKER) ? '' : l));
  const at = (i) => (binary ? {} : { line: i + 1 });

  lines.forEach((line, i) => {
    const lower = line.toLowerCase();
    if (PEM_KEY.test(line)) {
      out.push({ file, ...at(i), rule: 'private-key', message: 'PEM private key block' });
    }
    if (MODERN_UDID.test(line)) {
      out.push({ file, ...at(i), rule: 'device-udid', message: 'looks like an Apple device UDID' });
    }
    if (savedIds.some((id) => lower.includes(id))) {
      out.push({ file, ...at(i), rule: 'saved-device-id', message: 'matches a device ID saved in the sideload config' });
    }
    if (P12_PASS_RE.test(line) || securityPassword(line)) {
      out.push({ file, ...at(i), rule: 'p12-password', message: 'looks like a p12 password assignment' });
    }
  });

  const profileText = lines.join('\n');
  const hasProfile = profileText.includes(PROFILE_EXPIRY)
    && (profileText.includes(PROFILE_DEVICES) || profileText.includes(PROFILE_TEAM));
  if (hasProfile) {
    out.push({ file, rule: 'provisioning-profile', message: 'contains provisioning profile markers' });
  }
  return out;
}

// Map staged paths to index entries. Reading by blob ID (not `:<path>`) means a
// path like `0:t.txt` cannot be misparsed as stage 0 of `t.txt`.
async function stagedEntries(root) {
  const entries = new Map();
  for (const rec of splitZ(await git(root, ['ls-files', '-s', '-z']))) {
    const tab = rec.indexOf('\t');
    const [mode, oid, stage] = rec.slice(0, tab).split(' ');
    if (stage === '0') entries.set(rec.slice(tab + 1), { mode, oid });
  }
  return entries;
}

async function readStaged(root, entry) {
  if (!entry) throw new Error('a staged file has no stage-0 index entry (unresolved conflict?)');
  if (entry.mode === '160000') return null; // submodule gitlink: no content
  const size = Number((await git(root, ['cat-file', '-s', entry.oid])).trim());
  if (size > MAX_BYTES) return { size };
  return { size, buf: await git(root, ['cat-file', 'blob', entry.oid], { buffer: true }) };
}

async function readWorking(root, file) {
  let st;
  try {
    st = await lstat(join(root, file));
  } catch (err) {
    if (err.code === 'ENOENT') return null; // tracked but deleted
    throw err;
  }
  if (!st.isFile()) return null; // symlinks, submodules
  if (st.size > MAX_BYTES) return { size: st.size };
  return { size: st.size, buf: await readFile(join(root, file)) };
}

// IDs loaded so far, so error text (which can quote paths) is redacted too.
let knownIds = [];

async function main() {
  const mode = parseMode(process.argv.slice(2));
  const root = (await run('git', ['rev-parse', '--show-toplevel'])).stdout.trim();
  const savedIds = await loadSavedDeviceIds();
  knownIds = savedIds;

  let files;
  let entries;
  if (mode === 'staged') {
    files = splitZ(await git(root, ['diff', '--cached', '--name-only', '--diff-filter=d', '-z']));
    entries = await stagedEntries(root);
  } else {
    const tracked = splitZ(await git(root, ['ls-files', '-z']));
    const untracked = splitZ(await git(root, ['ls-files', '--others', '--exclude-standard', '-z']));
    files = [...new Set([...tracked, ...untracked])];
  }

  const findings = [];
  let scanned = 0;
  for (const file of files) {
    findings.push(...checkPath(file, savedIds));
    const data = mode === 'staged' ? await readStaged(root, entries.get(file)) : await readWorking(root, file);
    if (!data) continue;
    scanned++;
    if (!data.buf) {
      findings.push({ file, rule: 'oversize', message: `file exceeds ${MAX_BYTES} bytes and was not scanned` });
      continue;
    }
    findings.push(...checkContent(file, data.buf, savedIds));
  }

  for (const f of findings) f.file = redactPath(f.file, savedIds);
  return { ok: findings.length === 0, mode, scanned, findings };
}

function emit(result, code) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = code;
}

try {
  const result = await main();
  emit(result, result.ok ? 0 : 1);
} catch (err) {
  const mode = process.argv.includes('--all') ? 'all' : process.argv.includes('--staged') ? 'staged' : null;
  emit({ ok: false, mode, scanned: 0, findings: [], error: redactPath(String(err?.message ?? err), knownIds) }, 2);
}
