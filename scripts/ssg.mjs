#!/usr/bin/env node
/**
 * scripts/ssg.mjs — static-site-generator build step for the fx-init docs site.
 *
 * Multi-route SSG: pre-renders EACH of the 6 Elm content pages to its own
 * dist/<dir>/index.html so deep-links + no-JS/SEO work under Caddy static
 * hosting. Client-only playground pages (the /fx-init/demo WASM terminal)
 * get a client-only shell page instead — see step 5.
 *
 * Pipeline:
 *   1. Expects the Elm app already compiled to `dist/elm.js`:
 *        elm make src/Main.elm --output=dist/elm.js --optimize
 *   2. Boots a happy-dom `Window`, installs its browser globals onto globalThis,
 *      then loads the compiled Elm bundle ONCE with an indirect eval.
 *   3. For each content page (from CONTENT_PAGES): mounts Elm.Main.init with
 *      flags { pathname: page.path } and reads back innerHTML.
 *   4. Wraps the markup in a full HTML document (import map + the page's slot).
 *   5. For each playground page (from PLAYGROUND_PAGES — the client-only
 *      /fx-init/demo WASM terminal, a NON-Elm @mfe module): writes the same
 *      document wrapper with an EMPTY slot and NO Elm render. The page is
 *      still served statically (deep-links resolve), and shell.js's `ssr`
 *      rehydration reconciles the existing DOM, mounting the slot's MFE at
 *      load — the terminal boots entirely client-side.
 *   6. Copies shell/ -> dist/ and vendor/@mfe -> dist/vendor/@mfe (if present).
 *      shell/ carries the demo's assets too (the wasm build in shell/wasm +
 *      the xterm vendor in shell/vendor/xterm), copied verbatim like the rest
 *      of shell/.
 *
 * Run from the repo root:  node scripts/ssg.mjs
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Window } from 'happy-dom';
import { PAGES, CONTENT_PAGES, PLAYGROUND_PAGES } from '../shell/pages.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const DIST = join(ROOT, 'dist');
const ELM_BUNDLE = join(DIST, 'elm.js');

// The import map is shared by every generated page. All paths are ABSOLUTE
// (/fx-init/...) because the 6 pages live at different URL depths. @mfe/core
// and @mfe/framework resolve to the shared main-site vendor/ (served by the
// fixpointlinux.org host); fixpoint-landing resolves to the main-site shell.
const IMPORT_MAP = `{
  "imports": {
    "@mfe/core": "/vendor/@mfe/core/index.js",
    "@mfe/framework": "/vendor/@mfe/framework/index.js",
    "fx-init-landing": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-boot": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-supervise": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-activate": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-fxctl": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-logs": "/fx-init/shell/mfe/fx-init-page.js",
    "fx-init-demo": "/fx-init/shell/mfe/fx-init-demo.js",
    "fixpoint-landing": "/shell/mfe/fixpoint-landing.js"
  }
}`;

function log(msg) {
  console.log(`[ssg] ${msg}`);
}

/** Wrap a slot body in a full HTML document with the shared import map. */
function wrapDocument(title, description, slotHtml) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<meta name="description" content="${description}">
<script type="importmap">
${IMPORT_MAP}
</script>
</head>
<body>
<div id="app" ssr>
  <div class="fixpoint-root">
${slotHtml}
  </div>
</div>
<script type="module" src="/fx-init/shell/shell.js"></script>
</body>
</html>
`;
}

/** The slot element for a page (indented 4 spaces to fit wrapDocument). */
function slotHtml(slotName, inner) {
  const rendered = inner === undefined ? '' : `\n${inner}\n    `;
  return `    <div data-mfe="${slotName}">${rendered}</div>`;
}

/**
 * Install happy-dom's window-backed values onto globalThis so the compiled Elm
 * bundle and its runtime see a browser-shaped global object.
 */
function installGlobals(window) {
  const globals = [
    'window', 'document', 'navigator', 'location', 'history',
    'customElements', 'performance', 'requestAnimationFrame', 'cancelAnimationFrame',
    'HTMLElement', 'HTMLDivElement', 'HTMLSpanElement', 'HTMLAnchorElement',
    'HTMLButtonElement', 'HTMLTableElement', 'Element', 'Node', 'Document',
    'DocumentFragment', 'Text', 'Comment', 'NodeList', 'HTMLCollection',
    'Event', 'CustomEvent', 'MouseEvent', 'KeyboardEvent', 'UIEvent',
    'EventTarget', 'MutationObserver', 'getComputedStyle', 'matchMedia',
  ];
  for (const name of globals) {
    const value = window[name];
    if (value === undefined) continue;
    Object.defineProperty(globalThis, name, {
      value,
      configurable: true,
      writable: true,
    });
  }
}

/** Load the compiled Elm bundle ONCE into globalThis.Elm. */
function loadElmOnce() {
  if (globalThis.__fxInitElmLoaded) return;
  const code = readFileSync(ELM_BUNDLE, 'utf8');
  // eslint-disable-next-line no-eval -- indirect eval runs in global scope.
  (0, eval)(code);
  globalThis.__fxInitElmLoaded = true;
}

/** Mount the Elm app with the given pathname flag and return the rendered HTML. */
async function renderPage(window, pathname) {
  const Elm = globalThis.Elm;
  if (!Elm || !Elm.Main || typeof Elm.Main.init !== 'function') {
    throw new Error('dist/elm.js did not expose Elm.Main.init on globalThis');
  }
  const root = window.document.createElement('div');
  root.setAttribute('id', 'docs-root');
  window.document.body.appendChild(root);
  Elm.Main.init({ node: root, flags: { pathname } });
  const flush = window.happyDOM && typeof window.happyDOM.whenAsyncComplete === 'function'
    ? () => window.happyDOM.whenAsyncComplete()
    : () => new Promise((resolve) => setTimeout(resolve, 0));
  await flush();
  await flush();
  return root.innerHTML;
}

/** Copy a file or directory tree from src to dest. Uses readFileSync +
 *  writeFileSync instead of cpSync to avoid EPERM when the sandbox overlayfs
 *  refuses to preserve timestamps / mode bits on the destination. */
function copyRecursive(src, dest) {
  const stats = statSync(src);
  if (stats.isDirectory()) {
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(src)) {
      copyRecursive(join(src, entry), join(dest, entry));
    }
  } else {
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, readFileSync(src));
  }
}

async function main() {
  if (!existsSync(ELM_BUNDLE)) {
    console.error(
      `[ssg] missing ${ELM_BUNDLE}. Build it first:\n` +
        '  elm make src/Main.elm --output=dist/elm.js --optimize',
    );
    process.exit(1);
  }

  const window = new Window();
  installGlobals(window);
  loadElmOnce();

  // Render each content page to dist/<dir>/index.html.
  for (const page of CONTENT_PAGES) {
    log(`rendering ${page.slot} (path=${page.path}) ...`);
    const rendered = await renderPage(window, page.path);
    log(`  rendered ${rendered.length} bytes`);

    const outputDir = page.dir === '' ? DIST : join(DIST, page.dir);
    const outputPath = join(outputDir, 'index.html');
    const finalHtml = wrapDocument(page.title, page.title, slotHtml(page.slot, rendered));
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(outputPath, finalHtml);
    log(`  wrote ${outputPath} (${finalHtml.length} bytes)`);
  }

  // Client-only playground pages (non-Elm MFE, e.g. the /fx-init/demo WASM
  // terminal): NOT Elm-pre-rendered — emit the same document wrapper with an
  // EMPTY slot. The `ssr` attribute still applies: shell.js's createApp
  // rehydrates the existing DOM, and reconcile mounts the slot's MFE into the
  // empty div at load, so the deep-link resolves statically while the
  // interactive content boots client-side.
  for (const page of PLAYGROUND_PAGES) {
    log(`client-only ${page.slot} (path=${page.path}) — not pre-rendered`);
    const outputDir = page.dir === '' ? DIST : join(DIST, page.dir);
    const outputPath = join(outputDir, 'index.html');
    const finalHtml = wrapDocument(page.title, page.title, slotHtml(page.slot));
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(outputPath, finalHtml);
    log(`  wrote ${outputPath} (${finalHtml.length} bytes)`);
  }

  // Copy shell/ to dist/ (templates + mfe modules + pages.js + shell.js).
  log('copying shell/ to dist/ ...');
  copyRecursive(join(ROOT, 'shell'), join(DIST, 'shell'));

  // Copy vendor/@mfe to dist/vendor/@mfe (built by the mfe-framework target).
  const vendorMfeSrc = join(ROOT, 'vendor', '@mfe');
  if (existsSync(vendorMfeSrc)) {
    log('copying vendor/@mfe to dist/vendor/@mfe ...');
    copyRecursive(vendorMfeSrc, join(DIST, 'vendor', '@mfe'));
  }

  log('SSG complete.');
}

main().catch((err) => {
  console.error('[ssg] failed:', err);
  process.exit(1);
});
