// shell/mfe/fx-init-demo.js — the fx-init in-browser userland demo as a
// non-Elm @mfe MFE module.
//
// Unlike the content pages (fx-init-page.js -> Elm), this page hosts an
// interactive xterm.js terminal that drives the REAL fx-init userland CLIs —
// fxstore, fx-activate, fxctl, dhall — compiled to WebAssembly and running
// against an in-memory /fx/store (MEMFS). It is NOT Elm-ified (the dafsa
// playground precedent): it injects its own CSS + the vendored xterm.css and
// builds its own DOM, so it gets no Fixpoint.Style stylesheet.
//
// How it works (mirrors shen/shell/mfe/shen-playground.js — the org's existing
// xterm + wasm terminal MFE):
//   1. Loads the vendored xterm.js (classic <script> -> global `Terminal`) and
//      the compiled emscripten module shell/wasm/fx-shell.js (classic
//      <script> -> global `createFxShell`; it is CommonJS-emitted so in the
//      browser `exports`/`module` are undefined and the factory lands as a
//      global — reviewer-confirmed contract). The artifact is `.js` because
//      Caddy serves `.js` as a JS MIME type (a `.cjs` classic <script> would be
//      refused as text/plain under strict MIME checking).
//   2. Boots the module once (module-level cache; ONE MEMFS = ONE virtual
//      machine for the whole page session, so /fx/store persists across
//      re-mounts) and runs the EXACT browser-boot smoke sequence from
//      tests/fxshell-smoke.js: scaffold demo/*.dhall into MEMFS, fxstore build,
//      fx-activate twice (second with a changed hostname), timeline, a computed
//      rollback, dhall normalize, fxctl honest-fail.
//   3. Wires the terminal: on Enter, dispatches to a small builtin table
//      (help/clear/ls/cat/pwd) or calls fxsh_run() via M.ccall and streams
//      Module.print/printErr to the terminal. fxsh_run is guarded in try/catch
//      for emscripten's ExitStatus, exactly like shen.
//
// BASE resolution: resolved from import.meta.url (module-relative, per the
// cross-origin MFE precedent) so the assets resolve whether the site is served
// at /fx-init/... — the module lives at shell/mfe/fx-init-demo.js and all
// classic-script assets live under the sibling shell/ dir.

import { PACKAGE_SET, CONFIG } from '../wasm/demo-files.js';

// This module sits at shell/mfe/fx-init-demo.js; one dir up is shell/.
const BASE = new URL('..', import.meta.url).href;
const XTERM_JS = `${BASE}vendor/xterm/xterm.js`;
const XTERM_CSS = `${BASE}vendor/xterm/xterm.css`;
const FX_SHELL = `${BASE}wasm/fx-shell.js`; // .wasm is colocated, derive by currentScript.src

// --- script loading (classic, cached per URL) ------------------------------
// The emscripten factory captures `document.currentScript.src` AT LOAD to
// derive scriptDirectory for locateFile("fx-shell.wasm") (see the top of
// fx-shell.js: `_scriptName=globalThis.document?.currentScript?.src`). It MUST
// therefore be loaded as a real <script src> tag (never fetch+eval, which
// leaves currentScript null) and the .wasm must sit next to the .js in
// shell/wasm/. Same constraint the dafsa-playground documents.
const scriptCache = new Map();

function loadScript(src) {
  if (scriptCache.has(src)) return scriptCache.get(src);
  const promise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.async = false; // preserve ordering
    s.onload = () => { s.remove(); resolve(); };
    s.onerror = () => { s.remove(); reject(new Error(`fx-init-demo: failed to load ${src}`)); };
    (document.head || document.documentElement).appendChild(s);
  });
  scriptCache.set(src, promise);
  return promise;
}

// --- module-level shared state (ONE module, ONE MEMFS per page session) ----
let shellPromise = null;      // createFxShell() factory promise (cached)
let M = null;                 // the resolved emscripten Module
let emit = null;              // current terminal writer, set per mount
// Output capture: Module.print/printErr push here; run() drains it. The array
// is reset per command by clearing length (the closures capture this object).
const cap = { lines: [] };

function capture(s, isErr) {
  cap.lines.push((isErr ? '[err] ' : '') + s);
}

// Build the module ONCE. createFxShell is a global factory; calling it again
// would instantiate a SECOND MEMFS (a fresh store), so we cache the promise and
// reuse the module across re-mounts — /fx/store survives unmount/mount.
function loadShell() {
  if (!shellPromise) {
    if (typeof createFxShell !== 'function') {
      throw new Error('createFxShell is not a global after loading ' + FX_SHELL);
    }
    shellPromise = createFxShell({
      print: (s) => capture(s, false),
      printErr: (s) => capture(s, true),
    }).then((module) => { M = module; return module; })
      .catch((err) => { shellPromise = null; throw err; });
  }
  return shellPromise;
}

// --- terminal + command plumbing -------------------------------------------
// Run one command line through fxsh_run, echoing the command and the captured
// stdout/stderr to the terminal. Returns { rc, text }. Guarded against
// emscripten's ExitStatus (fx_init tools return exit codes, but a tool that
// calls exit() would throw under EXIT_RUNTIME=0 — shen does the same guard).
function run(cmdline) {
  if (emit) emit(`\r\n$ ${cmdline}\r\n`);
  cap.lines.length = 0;
  let rc;
  try {
    rc = M.ccall('fxsh_run', 'number', ['string'], [cmdline]);
  } catch (e) {
    cap.lines.push(`<exited: ${e.message}>`);
    rc = -1;
  }
  const text = cap.lines.join('\r\n');
  if (emit && text) emit(text + '\r\n');
  return { rc, text };
}

// Parse version lines from `fxstore timeline` output (store.c:772):
//   "  %u%s roots: <names>  closure: N  store: N  srcstore: N"
// %u is the 1-indexed version, %s is " [CURRENT]" or "". Same logic as
// tests/fxshell-smoke.js so the browser boot and the node smoke agree.
function parseVersions(text) {
  const vers = [];
  for (const m of text.matchAll(/^\s*(\d+)(\s+\[CURRENT\])?\s+roots:/gm)) {
    vers.push({ n: parseInt(m[1], 10), current: !!m[2] });
  }
  return vers;
}

// --- builtin table (interactive mode) --------------------------------------
const BUILTINS = {
  help() {
    return [
      'fx-init demo terminal — builtins:',
      '  help            show this help',
      '  clear           clear the terminal',
      '  pwd             print the MEMFS working directory',
      '  ls [dir]        list a MEMFS directory',
      '  cat <file>      print a MEMFS file',
      'anything else runs the REAL CLI (fxstore / fx-activate / fxctl / dhall)',
      '  e.g.  fxstore timeline --store /fx/store',
    ].join('\r\n');
  },
  clear() { if (emit) emit('\x1b[2J\x1b[H'); return null; },
  pwd() { return M.FS.cwd(); },
  ls(args) {
    const dir = args[0] || M.FS.cwd();
    try {
      const names = M.FS.readdir(dir).filter((n) => n !== '.' && n !== '..');
      return names.length ? names.join('  ') : '(empty)';
    } catch (e) {
      return `<error: ${e.message}>`;
    }
  },
  cat(args) {
    if (!args.length) return 'usage: cat <file>';
    try {
      return M.FS.readFile(args[0], { encoding: 'utf8' });
    } catch (e) {
      return `<error: ${e.message}>`;
    }
  },
};

// Route one interactive line to a builtin or fxsh_run.
function dispatch(cmdline) {
  const trimmed = cmdline.trim();
  if (!trimmed) return;
  const tokens = trimmed.split(/\s+/);
  const cmd = tokens[0];
  const fn = BUILTINS[cmd];
  if (fn) {
    const out = fn(tokens.slice(1));
    if (out !== null && out !== undefined && emit) emit(out + '\r\n');
  } else {
    run(trimmed);
  }
}

// --- boot sequence (replicates tests/fxshell-smoke.js) ----------------------
async function bootSequence(term) {
  if (!M) throw new Error('fx-init-demo: shell module not booted');

  // 1. Scaffold the demo project in MEMFS exactly as the node smoke does.
  //    MEMFS has no /fx by default, so create the store root's parent first.
  M.FS.mkdirTree('/fx');
  M.FS.mkdirTree('/tmp/proj');
  for (const name of ['dhake', 'fxstore', 'fake-service', 'fx-init', 'fxctl', 'fx-activate']) {
    M.FS.mkdirTree('/tmp/proj/src/' + name);
    M.FS.writeFile('/tmp/proj/src/' + name + '/hello.txt', 'hello from ' + name + '\n');
  }
  M.FS.writeFile('/tmp/proj/package-set.dhall', PACKAGE_SET);
  M.FS.writeFile('/tmp/proj/config.dhall', CONFIG);
  M.FS.chdir('/tmp/proj');

  emit('\r\n[boot] demo project scaffolded in MEMFS (/tmp/proj, demo/*.dhall written)\r\n');

  // 2. fxstore build — the real build over the datalog-backed store in MEMFS
  //    (dl_open fcntl lock, closure fixpoint, snapshot publish, content hash).
  run('fxstore build --store /fx/store');

  // 3. fx-activate — renders a real system generation from config.dhall.
  run('fx-activate --store /fx/store');

  // 4. Activate AGAIN after a hostname change -> a second generation/version.
  const CONFIG2 = CONFIG.replace('"fixbox"', '"fixbox2"');
  M.FS.writeFile('/tmp/proj/config.dhall', CONFIG2);
  emit('\r\n[boot] changed hostname to fixbox2 in config.dhall, activating again\r\n');
  run('fx-activate --store /fx/store');

  // 5. Timeline: parse the real output and pick a rollback target.
  const tl = run('fxstore timeline --store /fx/store');
  const vers = parseVersions(tl.text);

  // 6. Computed roll-forward to the second-newest published version.
  if (vers.length >= 2) {
    const target = vers[vers.length - 2].n;
    run(`fxstore rollback ${target} --store /fx/store`);
  } else {
    emit('\r\n[boot] (fewer than 2 versions — skipping rollback step)\r\n');
  }

  // 7. dhall normalize over a MEMFS file.
  M.FS.writeFile('/tmp/proj/hello.dhall', 'let greeting = "hello from dhall" in greeting');
  run('dhall normalize hello.dhall');

  // 8. fxctl honest-fail: no PID1 / AF_UNIX socket in a browser, so the real
  //    fxctl returns non-zero with its real not-running/connect error.
  run('fxctl status');

  // 9. Closure query LAST (it opens the store and publishes a snapshot, so it
  //    must not run before the timeline/rollback steps).
  run('fxstore query fx-init --store /fx/store');
}

// --- DOM + CSS -------------------------------------------------------------
// Minimal DOM builder helper.
function el(tag, attrs, children) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (k === 'class') node.className = v;
      else if (k === 'html') node.innerHTML = v;
      else node.setAttribute(k, v);
    }
  }
  for (const c of children || []) {
    node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return node;
}

// Consolidated demo CSS: the fixpoint palette + the story-blurb / status /
// terminal layout. Self-contained since this MFE is not Elm and gets no
// Fixpoint.Style stylesheet (dafsa-playground precedent).
const DEMO_CSS = `
:root{--fx-bg:#0b0e11;--fx-bg2:#10141a;--fx-fg:#d8dee6;--fx-dim:#7d8794;--fx-accent:#6ad6a1;--fx-accent2:#8ab4f8;--fx-line:#1e2730;--fx-mono:"SFMono-Regular","Cascadia Code","JetBrains Mono","Fira Code",Menlo,Consolas,monospace;--fx-sans:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.fx-demo{max-width:960px;margin:0 auto;padding:24px;font-family:var(--fx-sans);line-height:1.6;color:var(--fx-fg)}
.fx-demo h1{font-size:clamp(26px,4.5vw,38px);font-weight:750;letter-spacing:-0.02em;margin:0 0 0.3em}
.fx-demo .blurb{background:#1a2e24;border-left:4px solid var(--fx-accent);padding:12px 16px;border-radius:6px;margin:0.6em 0 1em;color:#d8dee6}
.fx-demo .blurb p{margin:0.4em 0}
.fx-demo .blurb code{font-family:var(--fx-mono);font-size:0.9em;background:var(--fx-bg2);border:1px solid var(--fx-line);border-radius:5px;padding:1px 6px;color:var(--fx-accent)}
.fx-demo .blurb a{color:var(--fx-accent2);text-decoration:none}
.fx-demo .blurb a:hover{text-decoration:underline}
.fx-demo .status{font-family:var(--fx-mono);font-size:13px;color:var(--fx-dim);margin:0 0 8px}
.fx-demo .status.done{color:var(--fx-accent)}
.fx-demo .term-host{background:var(--fx-bg2);border:1px solid var(--fx-line);border-radius:10px;padding:6px;min-height:320px}
.fx-demo .term-host .xterm{height:100%;padding:4px}
.fx-demo .hint{font-family:var(--fx-mono);font-size:12px;color:var(--fx-dim);margin:10px 0 0}
`;

const CSS_IDS = {
  xterm: 'fx-init-demo-xterm-css',
  demo: 'fx-init-demo-css',
};

function injectStyles() {
  const head = document.head || document.documentElement;
  const added = [];
  if (!document.getElementById(CSS_IDS.xterm)) {
    const link = document.createElement('link');
    link.id = CSS_IDS.xterm;
    link.rel = 'stylesheet';
    link.href = XTERM_CSS;
    head.appendChild(link);
    added.push(link);
  }
  if (!document.getElementById(CSS_IDS.demo)) {
    const style = document.createElement('style');
    style.id = CSS_IDS.demo;
    style.textContent = DEMO_CSS;
    head.appendChild(style);
    added.push(style);
  }
  return added;
}

// --- MFE lifecycle (per @mfe/core types.ts; ctx optional so the standalone
//      demo page can call mount(container) with no host) --------------------
const live = new WeakMap();
const headTags = new WeakMap();

function clearChildren(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

export default {
  async mount(element, ctx) {
    if (live.has(element)) return; // already mounted here
    clearChildren(element);

    // Inject xterm.css + demo CSS (self-contained; no Fixpoint.Style).
    const added = injectStyles();
    headTags.set(element, added);

    // Build the demo DOM.
    const status = el('p', { class: 'status' }, ['running the boot sequence…']);
    const termHost = el('div', { class: 'term-host' });
    element.appendChild(el('div', { class: 'fx-demo' }, [
      el('h1', null, ['fx-init in your browser']),
      el('div', { class: 'blurb', html:
        "<p><strong>What's real here:</strong> <code>fxstore</code>, <code>fx-activate</code>, " +
        '<code>fxctl</code> and <code>dhall</code> are the <em>real</em> fixpoint-linux CLIs, ' +
        'compiled to WebAssembly and running against an in-memory <code>/fx/store</code> ' +
        '(MEMFS). The boot log below is genuinely computed in your browser: <code>fxstore</code> ' +
        'builds the demo package set, <code>fx-activate</code> renders two real system ' +
        'generations (the second after a hostname change), <code>fxstore timeline</code> shows ' +
        'the version history, a rollback rolls forward, <code>dhall</code> normalizes a file — ' +
        'and <code>fxctl</code> <em>honestly fails</em>: in a browser there is no PID1 and no ' +
        'control.sock, so the real fxctl reports that. For the PID1 / supervision side of ' +
        'fx-init, see <a href="/fx-init/boot" data-mfe-route="/fx-init/boot">the boot page</a> ' +
        'and <a href="/fx-init/supervise" data-mfe-route="/fx-init/supervise">supervise</a>.</p>' }),
      status,
      termHost,
      el('p', { class: 'hint' }, 'boot complete — type "help", "ls", "cat config.dhall", or "fxstore timeline".'),
    ]));

    // Load classic scripts, then create the module (cached; reuses MEMFS).
    await loadScript(XTERM_JS);
    await loadScript(FX_SHELL);
    if (typeof Terminal === 'undefined') {
      throw new Error('Terminal is not defined after loading xterm.js');
    }
    await loadShell();

    // Create the terminal and point the shared writer at it.
    const term = new Terminal({
      cursorBlink: true,
      convertEol: true,
      fontSize: 13,
      theme: { background: '#0b0e11', foreground: '#c9d1d9' },
    });
    term.open(termHost);
    emit = (s) => term.write(s);
    // Test/debug hook: expose the terminal on the container so a harness can
    // read the full scrollback buffer (the boot log scrolls off the viewport).
    element.__fxTerm = term;

    // Run the boot sequence (asynchronously) then flip to interactive mode.
    try {
      await bootSequence(term);
      status.textContent = 'boot sequence complete — the terminal below is live.';
      status.classList.add('done');
    } catch (err) {
      status.textContent = `boot failed: ${err.message}`;
      term.write(`\r\n<boot error: ${err.message}>\r\n`);
    }

    // Interactive: an xterm line buffer; Enter dispatches to builtins or fxsh_run.
    let line = '';
    term.onData((data) => {
      const code = data.charCodeAt(0);
      if (code === 13) {
        // Enter
        term.write('\r\n');
        dispatch(line);
        line = '';
        term.write('fx$ ');
      } else if (code === 127 || code === 8) {
        // Backspace
        if (line.length > 0) {
          line = line.slice(0, -1);
          term.write('\b \b');
        }
      } else if (code === 3) {
        // Ctrl-C: clear the line.
        line = '';
        term.write('^C\r\nfx$ ');
      } else if (code === 4) {
        // Ctrl-D: exit this terminal session (module + MEMFS stay alive).
        term.write('\r\n(session closed — remount to reopen; the /fx/store persists)\r\n');
        term.dispose();
      } else {
        line += data;
        term.write(data);
      }
    });
    term.write('fx$ ');
    term.focus();

    live.set(element, term);
  },

  async unmount(element, ctx) {
    if (!live.has(element)) return;
    const term = live.get(element);
    if (term && typeof term.dispose === 'function') term.dispose();
    live.delete(element);
    const added = headTags.get(element);
    if (added) for (const node of added) node.remove();
    headTags.delete(element);
    clearChildren(element);
    emit = null;
  },

  async update(prev, next, ctx) {
    // The slot moved structurally (reconcile's UPDATE path): move the rendered
    // subtree from prev to next, preserving the live terminal. @mfe/core's
    // transplant covers the same-ref case; bail if refs are identical.
    if (prev === next) return;
    const term = live.get(prev);
    if (term) {
      live.delete(prev);
      live.set(next, term);
    }
    const tags = headTags.get(prev);
    if (tags) {
      headTags.delete(prev);
      headTags.set(next, tags);
    }
    clearChildren(next);
    for (const child of Array.from(prev.childNodes)) next.appendChild(child);
  },
};
