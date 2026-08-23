// shell/shell.js — @mfe/framework thin-shell entry for the fx-init MFE site.
//
// Boots the fx-init docs app with 7 routes:
//   '/'                   → template 'fixpoint'         (cross-nav home, main site)
//   '/fx-init'            → template 'fx-init-landing'
//   '/fx-init/boot'       → template 'fx-init-boot'
//   '/fx-init/supervise'   → template 'fx-init-supervise'
//   '/fx-init/activate'    → template 'fx-init-activate'
//   '/fx-init/fxctl'       → template 'fx-init-fxctl'
//   '/fx-init/logs'        → template 'fx-init-logs'
//
// Matching the main site means a data-mfe-route like '/fx-init' or '/'
// resolves the same way on either page, so cross-site MFE nav links agree.
//
// The pages ship statically pre-rendered (see scripts/ssg.mjs): the #app root
// carries an `ssr` attribute, so createApp rehydrates the existing DOM in
// place instead of wiping it and re-fetching the template on first paint.
//
// Rehydrate only when the current pathname (trailing-slash-stripped) matches
// a pre-rendered fx-init page (i.e. starts with /fx-init — ALL six pages are
// pre-rendered; the site is content-only, no browser playground).

import { createApp } from '@mfe/framework';

const app = await createApp({
  root: document.getElementById('app'),
  routes: [
    { path: '/', template: 'fixpoint', name: 'home' },
    { path: '/fx-init', template: 'fx-init-landing', name: 'fx-init-landing' },
    { path: '/fx-init/boot', template: 'fx-init-boot', name: 'fx-init-boot' },
    { path: '/fx-init/supervise', template: 'fx-init-supervise', name: 'fx-init-supervise' },
    { path: '/fx-init/activate', template: 'fx-init-activate', name: 'fx-init-activate' },
    { path: '/fx-init/fxctl', template: 'fx-init-fxctl', name: 'fx-init-fxctl' },
    { path: '/fx-init/logs', template: 'fx-init-logs', name: 'fx-init-logs' },
  ],
  basePath: '/',
  // fx-init's templates are served from /fx-init/shell/templates
  // (the main site owns /shell/templates). Pin the baseURL here so both route
  // templates resolve under this site's shell regardless of the deep-link subpath.
  baseURL: '/fx-init/shell/templates',
  // The SSG output pre-renders all six content pages. Rehydrate whenever the
  // current pathname is an /fx-init route.
  ssr: (() => {
    const path = (window.location.pathname.replace(/\/+$/, '') || '/');
    return path.startsWith('/fx-init');
  })(),
});

// Expose the app handle so the shell/host can inspect or drive it later.
window.__fxInitApp = app;
