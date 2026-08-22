/* fx_reloc.h — store-relocatability helper for the fixpoint-linux M4 init.
 *
 * Activation (fx-activate) runs on the host and bakes the HOST store root into
 * the per-generation dhake buildfile:
 *
 *     let GEN = "<host_store>/<genhash>-system-generation"
 *     ...
 *     < Copy       = { from = GEN ++ "/etc/hostname", to = "/etc/hostname" } >
 *     < Symlink    = { from = "<host_store>/<hash>-<pkg>", to = "/bin/<name>" } >
 *
 * fx-init boots in a chroot where the store is relocated (e.g. /fx/store), so
 * those host-absolute paths do not resolve and dhake's rootfs materialization
 * fails with ENOENT.  fx_init therefore rewrites every occurrence of the
 * activation-time host store root to its own --store root before exec'ing
 * dhake.  The `to` paths (/etc/..., /bin/..., /run/...) are absolute and never
 * live under the store, so they are untouched.
 *
 * The rewrite is a pure string transform, extracted here so it can be unit
 * tested in isolation (tests/reloctest.c) without a store DB or bwrap.
 */
#ifndef FX_RELOC_H
#define FX_RELOC_H

#ifdef __cplusplus
extern "C" {
#endif

/* Rewrite `text` (a dhake buildfile) so store-absolute paths resolve under
 * `new_store`.  Derives the activation-time host store root from the
 * `let GEN = "<host_store>/<...>"` binding (everything up to its last '/'),
 * then replaces every occurrence of that host root with `new_store`.
 *
 * Returns a malloc'd NUL-terminated string the caller must free, or NULL on
 * failure (malformed buildfile with no `let GEN = "..."`, no '/' in GEN, or
 * out of memory).  When the host root equals "/" (GEN already /-absolute) the
 * text is returned unchanged (no rewrite needed / nothing sensible to do). */
char *fx_reloc_rewrite_buildfile(const char *text, const char *new_store);

#ifdef __cplusplus
}
#endif
#endif /* FX_RELOC_H */
