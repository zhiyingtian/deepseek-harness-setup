// Offline fixtures exercise installer orchestration, not the official npm runtime.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const net = require('node:net');
const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const { test } = require('node:test');

const root = __dirname;
const testRoot = path.join(root, '.test-work');
fs.mkdirSync(testRoot, { recursive: true });

function run(command, args, env) {
  return new Promise(resolve => {
    const child = spawn(command, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 30000);
    child.on('close', code => { clearTimeout(timer); resolve({ code, stdout, stderr }); });
  });
}

async function unusedPort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('default install root is under HOME and dry-run does not create it', async () => {
  const home = fs.mkdtempSync(path.join(testRoot, 'home-'));
  const env = { ...process.env, HOME: home };
  delete env.DSH_BASE;
  try {
    const result = await run('bash', ['install-upgrade.sh', '--dry-run'], env);
    assert.equal(result.code, 0, result.stderr);
    assert.ok(result.stdout.includes(`[PLAN] Install root: ${path.join(home, 'deepseek-harness')}`));
    assert.equal(fs.existsSync(path.join(home, 'deepseek-harness')), false);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('online installer: install, restart, upgrade, data backup and failed-start rollback', async () => {
  const directory = fs.mkdtempSync(path.join(testRoot, 'install-'));
  const base = path.join(directory, 'runtime');
  const tools = path.join(directory, 'tools');
  const version = 'v22.23.4';
  const arch = os.arch() === 'arm64' ? 'linux-arm64' : 'linux-x64';
  const nodeName = `node-${version}-${arch}`;
  const fixtureNode = path.join(directory, nodeName);
  const curl = execFileSync('which', ['curl'], { encoding: 'utf8' }).trim();
  fs.mkdirSync(path.join(fixtureNode, 'bin'), { recursive: true });
  fs.mkdirSync(tools);
  fs.symlinkSync(process.execPath, path.join(fixtureNode, 'bin/node'));
  // Use a real HTTP listener to cover DSH's token-to-cookie redirect flow.
  const cli = `
const fs = require('node:fs');
const http = require('node:http');
const args = process.argv.slice(2);
const version = fs.readFileSync(__dirname + '/version.txt', 'utf8');
if (args[0] === '--version') { console.log(version); process.exit(0); }
if (args[0] === 'plugin') {
 if (args.join(' ') !== 'plugin --profile web add dshmarket') process.exit(2);
 if (process.env.TEST_PLUGIN_FAIL === '1') process.exit(1);
 const path = require('node:path');
 const profile = path.join(process.env.DSH_HOME, 'profiles/web');
 fs.mkdirSync(profile, {recursive:true});
 const file = path.join(profile, 'package.json');
 const pkg = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : {};
 (pkg.dependencies ||= {}).dshmarket = '1.66.47';
 (((pkg.dsh ||= {}).profile ||= {}).bundles ||= []);
 if (!pkg.dsh.profile.bundles.includes('dshmarket')) pkg.dsh.profile.bundles.push('dshmarket');
 fs.writeFileSync(file, JSON.stringify(pkg));
 process.exit(0);
}
if (version === '9.9.9') { console.error('fixture startup failure'); process.exit(1); }
if (args.includes('--port')) { console.error('default port must not be overridden'); process.exit(2); }
const port = Number(process.env.TEST_PORT);
const server = http.createServer((request, response) => {
 if (request.url.includes('token=')) { response.writeHead(303, { Location: '/', 'Set-Cookie': 'dsh=test; HttpOnly' }); response.end(); }
 else if (request.headers.cookie === 'dsh=test') { response.end('ok'); }
 else { response.writeHead(401); response.end(); }
});
server.listen(port, '127.0.0.1', () => console.log('dsh web: http://127.0.0.1:' + port + '/?token=test'));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`;
  fs.writeFileSync(path.join(fixtureNode, 'bin/npm'), `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const version = process.env.TEST_VERSION || '1.0.0';
if (args[0] === 'view') { console.log(JSON.stringify(version)); process.exit(0); }
if (args[0] !== 'install') process.exit(2);
if (process.env.TEST_INSTALL_FAIL === '1') process.exit(1);
if (!args.includes('pnpm@11.7.0')) process.exit(2);
const prefix = args[args.indexOf('--prefix') + 1];
const lib = path.join(prefix, 'node_modules/@deepseek-ai/dsh/lib');
fs.mkdirSync(lib, {recursive:true});
fs.writeFileSync(path.join(lib, 'bin.js'), ${JSON.stringify(cli)});
fs.writeFileSync(path.join(lib, 'version.txt'), version);
`, { mode: 0o755 });
  const archive = path.join(directory, nodeName + '.tar.xz');
  execFileSync('tar', ['cJf', archive, '-C', directory, nodeName]);
  const checksum = crypto.createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
  fs.writeFileSync(path.join(tools, 'curl'), `#!/usr/bin/env node
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
if (args.includes('--write-out')) {
 const result = spawnSync(${JSON.stringify(curl)}, args, {stdio:'inherit'}); process.exit(result.status ?? 1);
}
const output = args[args.indexOf('-o') + 1];
if (args.some(arg => arg.endsWith('/index.json'))) fs.writeFileSync(output, JSON.stringify([{version:${JSON.stringify(version)},lts:'test'}]));
else if (args.some(arg => arg.endsWith('/SHASUMS256.txt'))) fs.writeFileSync(output, ${JSON.stringify(checksum + '  ' + nodeName + '.tar.xz\n')});
else fs.copyFileSync(${JSON.stringify(archive)}, output);
`, { mode: 0o755 });
  // Redirect downloads and package installation into this disposable fixture only.
  const env = { ...process.env, PATH: tools + ':' + process.env.PATH, DSH_BASE: base, TEST_PORT: String(await unusedPort()) };
  delete env.NODE_VERSION;
  async function install(extraEnv = {}, args = []) {
    return run('bash', ['install-upgrade.sh', ...args], { ...env, ...extraEnv });
  }
  try {
    let result = await install({}, ['--dry-run']);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(fs.existsSync(base), false);
    assert.match(result.stdout, /DSH default port \(3080\)/);
    assert.match(result.stdout, /plugin=dshmarket/);
    result = await install();
    assert.equal(result.code, 0, result.stdout + result.stderr);
    assert.match(result.stdout, /HTTP 200/);
    assert.match(result.stdout, /\[DONE\] Web link \(keep token private\): http:\/\/127\.0\.0\.1:\d+\/\?token=test/);
    assert.match(result.stdout, /SSH: ssh -L /);
    assert.doesNotMatch(result.stdout, /ssh -N/);
    const first = fs.readlinkSync(path.join(base, 'current'));
    const profilePackage = path.join(base, 'data/profiles/web/package.json');
    let profile = JSON.parse(fs.readFileSync(profilePackage));
    assert.equal(profile.dependencies.dshmarket, '1.66.47');
    assert(profile.dsh.profile.bundles.includes('dshmarket'));
    profile.dependencies['existing-plugin'] = '2.0.0';
    profile.dsh.profile.bundles.push('existing-plugin');
    fs.writeFileSync(profilePackage, JSON.stringify(profile));
    fs.writeFileSync(path.join(base, 'data/user-setting.json'), '{"preserve":true}');
    result = await run('bash', ['dshctl.sh', 'restart'], env);
    assert.equal(result.code, 0, result.stdout + result.stderr);
    result = await install({ TEST_VERSION: '1.0.1' });
    assert.equal(result.code, 0, result.stdout + result.stderr);
    const upgraded = fs.readlinkSync(path.join(base, 'current'));
    assert.notEqual(upgraded, first);
    assert.equal(fs.readFileSync(path.join(base, 'data/user-setting.json'), 'utf8'), '{"preserve":true}');
    assert.equal(fs.readdirSync(path.join(base, 'backups')).length, 1);
    const previousProfile = fs.readFileSync(profilePackage, 'utf8');
    assert.equal(JSON.parse(previousProfile).dependencies['existing-plugin'], '2.0.0');
    result = await install({ TEST_VERSION: '9.9.9' });
    assert.equal(result.code, 1);
    assert.equal(fs.readlinkSync(path.join(base, 'current')), upgraded);
    assert.equal(fs.readFileSync(profilePackage, 'utf8'), previousProfile);
    result = await run('bash', ['dshctl.sh', 'running'], env);
    assert.equal(result.code, 0, result.stderr);
    result = await install({ TEST_INSTALL_FAIL: '1' });
    assert.equal(result.code, 1);
    assert.equal(fs.readlinkSync(path.join(base, 'current')), upgraded);
    result = await run('bash', ['dshctl.sh', 'running'], env);
    assert.equal(result.code, 0);
    result = await install({ TEST_PLUGIN_FAIL: '1' });
    assert.equal(result.code, 1);
    assert.equal(fs.readlinkSync(path.join(base, 'current')), upgraded);
    assert.equal(fs.readFileSync(profilePackage, 'utf8'), previousProfile);
    result = await run('bash', ['dshctl.sh', 'running'], env);
    assert.equal(result.code, 0);
    result = await install({ NETWORK_TIMEOUT: '0' }, ['--dry-run']);
    assert.equal(result.code, 1);
    result = await install({}, ['--version', '../bad', '--dry-run']);
    assert.equal(result.code, 1);
  } finally {
    await run('bash', ['dshctl.sh', 'stop'], env);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});