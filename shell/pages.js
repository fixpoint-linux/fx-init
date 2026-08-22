// shell/pages.js — canonical page definitions for the fx-init MFE site.
//
// Single source of truth for all routes, templates, slots, and output paths.
// Imported by both shell/shell.js (browser ESM) and scripts/ssg.mjs (Node ESM).
//
// CANONICAL ROUTE TABLE (6 fx-init pages):
//   '/fx-init'            → template 'fx-init-landing'
//   '/fx-init/boot'       → template 'fx-init-boot'
//   '/fx-init/supervise'  → template 'fx-init-supervise'
//   '/fx-init/activate'   → template 'fx-init-activate'
//   '/fx-init/fxctl'      → template 'fx-init-fxctl'
//   '/fx-init/logs'       → template 'fx-init-logs'
//
// SLOT NAME == TEMPLATE NAME for all fx-init pages.
// The landing page's `dir` is '' so its output is dist/index.html.
// All other content pages have dir == slug, output to dist/<slug>/index.html.
// The site is content-only (no browser playground) — every page is type
// 'content' (Elm-rendered and pre-rendered by the SSG).
// The cross-nav home route '/' → 'fixpoint' is handled separately (main site
// owns /shell/templates/fixpoint.html and the importmap key 'fixpoint-landing').

export const PAGES = [
  {
    slug: 'fx-init',
    path: '/fx-init',
    slot: 'fx-init-landing',
    template: 'fx-init-landing',
    dir: '',
    title: 'fx-init — the fixpoint-linux M4 init system',
    type: 'content',
  },
  {
    slug: 'boot',
    path: '/fx-init/boot',
    slot: 'fx-init-boot',
    template: 'fx-init-boot',
    dir: 'boot',
    title: 'Boot — fx-init',
    type: 'content',
  },
  {
    slug: 'supervise',
    path: '/fx-init/supervise',
    slot: 'fx-init-supervise',
    template: 'fx-init-supervise',
    dir: 'supervise',
    title: 'Supervise — fx-init',
    type: 'content',
  },
  {
    slug: 'activate',
    path: '/fx-init/activate',
    slot: 'fx-init-activate',
    template: 'fx-init-activate',
    dir: 'activate',
    title: 'Activate — fx-init',
    type: 'content',
  },
  {
    slug: 'fxctl',
    path: '/fx-init/fxctl',
    slot: 'fx-init-fxctl',
    template: 'fx-init-fxctl',
    dir: 'fxctl',
    title: 'fxctl — fx-init',
    type: 'content',
  },
  {
    slug: 'logs',
    path: '/fx-init/logs',
    slot: 'fx-init-logs',
    template: 'fx-init-logs',
    dir: 'logs',
    title: 'Logs — fx-init',
    type: 'content',
  },
];

// All content pages (Elm-rendered) — all of fx-init's pages (content-only site).
export const CONTENT_PAGES = PAGES.filter((p) => p.type === 'content');

// Just the fx-init pages (all of them)
export const FXINIT_PAGES = PAGES;
