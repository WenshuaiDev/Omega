// Runs inside the pinned development image against a disposable source snapshot.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

function run(...args) {
  console.log(`yarn ${args.join(' ')}`);
  execFileSync('yarn', args, { stdio: 'inherit' });
}
function assert(condition, message) {
  if (!condition) throw new Error(message);
}
const mode = process.argv[2];
const root = JSON.parse(readFileSync('package.json', 'utf8'));
assert(process.version === `v${root.engines.node}`, 'Node runtime differs from package.json pin');
const yarn = execFileSync('yarn', ['--version'], { encoding: 'utf8' }).trim();
assert(root.packageManager === `yarn@${yarn}`, 'Yarn runtime differs from packageManager pin');
const members = execFileSync('yarn', ['workspaces', 'list', '--json'], { encoding: 'utf8' })
  .trim().split('\n').map((line) => JSON.parse(line));
const paths = new Set(members.map((member) => member.location));
function scan(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (['node_modules', '.git', '.yarn', '.quality-go', 'artifacts', 'dist'].includes(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) scan(path);
    else if (entry.name === 'yarn.lock') assert(path === 'yarn.lock', `additional lockfile: ${path}`);
    else if (entry.name === 'package.json') assert(paths.has(directory), `package missing from Yarn workspaces: ${path}`);
  }
}
scan('.');
for (const member of members) {
  const pkg = JSON.parse(readFileSync(join(member.location, 'package.json'), 'utf8'));
  for (const command of ['typecheck', 'lint', 'test']) assert(pkg.scripts?.[command], `${member.name} lacks ${command}`);
  if (member.location.startsWith('apps/')) assert(pkg.scripts?.build && pkg.scripts?.dev, `${member.name} lacks app build/dev`);
  for (const section of ['dependencies', 'devDependencies']) {
    for (const [name, version] of Object.entries(pkg[section] ?? {})) {
      if (members.some((item) => item.name === name)) assert(version.startsWith('workspace:'), `${name} requires workspace protocol`);
      else assert(/^\d+\.\d+\.\d+([+-][\w.-]+)?$/.test(version), `${name} is not exactly pinned`);
      if (root.devDependencies[name]) assert(root.devDependencies[name] === version, `${name} version differs between root/member`);
    }
  }
}
const lock = readFileSync('yarn.lock');
run('install', '--immutable');
assert(readFileSync('yarn.lock').equals(lock), 'immutable install changed yarn.lock');
assert(readFileSync('.yarnrc.yml', 'utf8').match(/^nodeLinker:\s*node-modules$/m), 'node-modules linker required');
if (mode === 'check') run('format:check');
for (const member of members.filter((member) => member.location !== '.')) {
  if (mode === 'check') {
    run('exec', 'prettier', '--check', member.location);
    run('workspace', member.name, 'typecheck');
    run('workspace', member.name, 'lint');
  }
  run('workspace', member.name, 'test');
  const pkg = JSON.parse(readFileSync(join(member.location, 'package.json'), 'utf8'));
  if (mode === 'check' && pkg.scripts.build) run('workspace', member.name, 'build');
}
assert(readFileSync('yarn.lock').equals(lock), 'checks changed yarn.lock');
