// tests/fxshell-smoke.js — FULL browser-boot smoke for the fx-shell wasm module
// (U2). Boots createFxShell from shell/wasm/fx-shell.cjs, then runs the EXACT
// lifecycle the browser demo will run over MEMFS, asserting on real tool output:
//
//   1. write demo/package-set.dhall + demo/config.dhall into MEMFS cwd and
//      chdir there (the browser JS driver does the same),
//   2. fxstore build --store /fx/store   — a real build over the datalog store
//   3. fx-activate                       — renders a REAL system generation
//   4. fx-activate again after a config change (hostname) — second version
//   5. fxstore timeline                  — >=3 versions; pick the rollback
//      target from the REAL output (1-indexed, each activate/query publishes)
//   6. fxstore rollback <target>         — roll-forward succeeds
//   7. dhall normalize on a MEMFS file
//   8. fxctl                            — honest non-zero failure (no PID1 /
//      AF_UNIX socket in wasm)
//   9. fxstore query (LAST — query publishes a snapshot, so it must not run
//      before the timeline/rollback steps or it shifts version numbers)
//
// Run:  node tests/fxshell-smoke.js     (from the fx-init repo root)
//
// The wasm artifact is emitted as `fx-shell.cjs` (NOT .js): fx-init's
// package.json has "type": "module", so a `.js` file would be treated as ESM
// and the emscripten MODULARIZE output's `module.exports = createFxShell`
// (CommonJS) would never run. `.cjs` forces CommonJS regardless of the
// package type, so `createRequire` + `require` returns the factory function —
// mirroring shen/tests/wasm-smoke.cjs. In the browser the same artifact is
// loaded as a CLASSIC <script>, where `exports`/`module` are undefined so
// `createFxShell` becomes a global (shen pattern).
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const require = createRequire(import.meta.url);
const createFxShell = require('../shell/wasm/fx-shell.cjs');

// Single source of truth: read the demo dhall sources straight from the repo
// (the browser boot inlines these; reading the files keeps the smoke runnable
// even without the build step's generated shell/wasm/demo-files.js present).
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const demoDir = path.join(__dirname, '..', 'demo');
const PACKAGE_SET = fs.readFileSync(path.join(demoDir, 'package-set.dhall'), 'utf8');
const CONFIG = fs.readFileSync(path.join(demoDir, 'config.dhall'), 'utf8');

const out = [];
const M = await createFxShell({
  print: (s) => out.push(s),
  printErr: (s) => out.push('[err] ' + s),
});

function run(cmdline) {
  out.length = 0;
  const rc = M.ccall('fxsh_run', 'number', ['string'], [cmdline]);
  return { rc, text: out.join('\n') };
}
function expect(cond, what) {
  if (!cond) {
    console.error('SMOKE FAIL: ' + what);
    console.error(out.join('\n'));
    process.exit(1);
  }
  console.log('ok: ' + what);
}

// Parse the version lines from `fxstore timeline` output. Format (store.c:772):
//   "  %u%s roots: <names>  closure: N  store: N  srcstore: N"
// where %u is the (1-indexed) version and %s is " [CURRENT]" or "". Returns
// {n, current} objects in ascending version order.
function parseVersions(text) {
  const vers = [];
  for (const m of text.matchAll(/^\s*(\d+)(\s+\[CURRENT\])?\s+roots:/gm)) {
    vers.push({ n: parseInt(m[1], 10), current: !!m[2] });
  }
  return vers;
}

// 0. tool help works (proves the renamed main + dispatch)
let r = run('fxstore --help');
expect(r.rc === 0 && r.text.includes('content-addressed build store'), 'fxstore --help');

// 1. scaffold the demo project in MEMFS exactly as the browser boot does.
//    MEMFS has no /fx by default (on a real host it is a mount point), so create
//    the store root's parent before any fxstore command touches /fx/store.
M.FS.mkdirTree('/fx');
M.FS.mkdirTree('/tmp/proj');
// src/<name>/ dirs hold the clean source each <Path> package is content-hashed
// from; content is irrelevant (only the hash is content-addressed).
for (const name of ['dhake', 'fxstore', 'fake-service', 'fx-init', 'fxctl', 'fx-activate']) {
  M.FS.mkdirTree('/tmp/proj/src/' + name);
  M.FS.writeFile('/tmp/proj/src/' + name + '/hello.txt', 'hello from ' + name + '\n');
}
M.FS.writeFile('/tmp/proj/package-set.dhall', PACKAGE_SET);
M.FS.writeFile('/tmp/proj/config.dhall', CONFIG);
M.FS.chdir('/tmp/proj');

// 2. THE crux: a full real build over the datalog-backed store in MEMFS against
//    the demo package set (exercises dl_open's fcntl lock, dl_compile closure
//    fixpoint, dl_publish_snapshot, content hashing, pure-FS recipes). Output
//    per package is `fxstore: built <store_root>/<hash>-<name>` (main.c:320).
r = run('fxstore build --store /fx/store');
expect(r.rc === 0 && r.text.includes('fxstore: built /fx/store/'), 'fxstore build (demo package set)');

// 3. real activation: reads config.dhall + package-set.dhall from cwd, computes
//    the closure, renders the generation (Dhakefile.dhall + etc/{hostname,
//    passwd,group} + /bin symlinks), writes store facts, publishes a snapshot.
//    Prints (fx-activate.c:826):
//      "activated <genhash> as version <v>; buildfile <path>"
r = run('fx-activate --store /fx/store');
expect(r.rc === 0 && r.text.includes('activated ') && r.text.includes('as version ')
       && r.text.includes('buildfile '), 'fx-activate generation (v1)');

// 4. activate AGAIN after a config change (hostname fixbox -> fixbox2): a
//    second activation with a different serialized generation yields a new
//    genhash + a new published snapshot version.
const CONFIG2 = CONFIG.replace('"fixbox"', '"fixbox2"');
M.FS.writeFile('/tmp/proj/config.dhall', CONFIG2);
r = run('fx-activate --store /fx/store');
expect(r.rc === 0 && r.text.includes('activated ') && r.text.includes('as version '),
       'fx-activate generation (v2, changed config)');

// 5. timeline: >=3 versions. The exact count depends on how many snapshots the
//    preceding commands published (build + 2 activations, and each store-opening
//    command may publish too), so parse the REAL output rather than hardcoding.
//    CURRENT is the highest published version.
r = run('fxstore timeline --store /fx/store');
expect(r.rc === 0 && r.text.includes('timeline of /fx/store'), 'fxstore timeline');
const vers = parseVersions(r.text);
expect(vers.length >= 3, 'timeline shows >= 3 versions (got ' + vers.length + ')');
const current = vers.find((v) => v.current) || vers[vers.length - 1];
expect(current.n === vers[vers.length - 1].n, 'CURRENT is the newest version');

// 6. roll-forward to a valid PRE-CURRENT version. Choose the second-newest
//    published version (the first activation's generation) — always a valid
//    rollback target (it is a published snapshot < CURRENT). Roll-forward
//    publishes a NEW version as CURRENT. Target computed from real timeline
//    output, since numbering is 1-indexed and every activate/query publishes.
const target = vers[vers.length - 2].n;
r = run('fxstore rollback ' + target + ' --store /fx/store');
expect(r.rc === 0, 'fxstore rollback ' + target + ' (roll-forward)');

// 7. dhall normalize over a MEMFS file. Mode + exit codes are from
//    vendor/dhall-c/src/main.c (normalize prints the normal form). The let-in
//    expression normalizes to the Text literal "hello from dhall".
M.FS.writeFile('/tmp/proj/hello.dhall', 'let greeting = "hello from dhall" in greeting');
r = run('dhall normalize hello.dhall');
expect(r.rc === 0 && r.text.includes('hello from dhall'), 'dhall normalize');

// 8. fxctl honest failure: in a browser there is no PID1 and no AF_UNIX socket,
//    so the REAL fxctl returns non-zero with its real not-running/connect error
//    (fxctl.c:138-144). This is the demo's honest-failure badge — never forced
//    to succeed.
r = run('fxctl status');
expect(r.rc !== 0 && (r.text.includes('not running') || r.text.includes('connect')),
       'fxctl fails honestly (no PID1/socket), rc=' + r.rc);

// 9. closure query (LAST — it opens the store and publishes a snapshot, so it
//    must not run before the timeline/rollback steps or it shifts versions).
//    fx-init depends on dhake + fxstore in the demo set (package-set.dhall), so
//    the closure is non-trivial. Output (main.c:391): closure list + store path.
r = run('fxstore query fx-init --store /fx/store');
expect(r.rc === 0 && r.text.includes('dhake') && r.text.includes('fxstore')
       && r.text.includes('store path'), 'fxstore query fx-init closure');

console.log('ALL FX-SHELL SMOKE TESTS PASSED');
