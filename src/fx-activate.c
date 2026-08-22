/* fx-activate.c — (U-B) build-time activation for the fixpoint-linux M4 init
 * system.
 *
 *   fx-activate [--store DIR] [--config PATH] [--package-set PATH]
 *
 * Flow:
 *   1. fx_packageset_load(package-set.dhall) + fx_config_load(config.dhall)
 *   2. fx_store_open
 *   3. compute_paths (reimplemented locally from fxstore/main.c — fxstore is a
 *      read-only vendored submodule, so the plan's "promote compute_paths into
 *      fxstore.h" is OFF the table) with roots = config.packages
 *   4. verify every closure package is BUILT (store fact + stat dir); require
 *      dhake/fx-init/fxctl in the closure
 *   5. resolve each service argv[0] against its pkg's store path + build.target
 *   6. render the generation in memory (Dhakefile.dhall + etc/hostname +
 *      etc/passwd + etc/group + extraEtc files)
 *   7. gen hash = sha256_hex over a canonical serialization
 *   8. write <root>.build/<pid>-gen/{Dhakefile.dhall,etc/*} then rename to
 *      <root>/<genhash>-system-generation (ADOPT if exists — content-addressed)
 *   9. declare + txn_add_fact the generation facts, dl_publish_snapshot
 *   10. print "activated <genhash> as version <v>; buildfile <path>"
 *
 * Links: config.c + packageset.c + derivation.c + closure.c + store.c +
 * dhall-c core + datalog-dafsa engine + dafsa.  NOT build.c (we never execute
 * a recipe) and NOT main.c.
 *
 * The emitted Dhakefile.dhall byte shape is the VALIDATED template from
 * handoff-fxinit-m4-artifact-1: /etc files via Copy{from=GEN/etc/<f>} + ALWAYS
 * Chmod (umask independence), every Symlink preceded by Rm<Plain> (dhake's
 * bare symlink(2) fails on EEXIST), all targets PHONY (always re-assert).
 */
#include "fx.h"
#include "fxstore.h"
#include "dhall.h"
#include "dl.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_STORE_ROOT "/fx/store"
#define DEFAULT_CONFIG      "config.dhall"
#define DEFAULT_PKGSET      "package-set.dhall"
#define ERR_CAP 4096

/* ─── CLI ─────────────────────────────────────────────────────────────────── */

static void usage(FILE *out) {
    fprintf(out,
        "fx-activate — fixpoint-linux M4 activation (build-time)\n"
        "usage:\n"
        "  fx-activate [--store DIR] [--config PATH] [--package-set PATH]\n"
        "    evaluates config.dhall, computes the closure, emits a per-generation\n"
        "    dhake buildfile, writes generation facts, publishes a store snapshot.\n"
        "  --store DIR        store root (default %s)\n"
        "  --config PATH      config.dhall path (default %s from cwd)\n"
        "  --package-set PATH package-set.dhall path (default %s from cwd)\n"
        "  -h, --help         show this help\n",
        DEFAULT_STORE_ROOT, DEFAULT_CONFIG, DEFAULT_PKGSET);
}

/* ─── PathEntry (local reimplementation of fxstore/main.c compute_paths) ─── */

typedef struct {
    Package *p;
    char *path;       /* store path of p */
    char *hash;       /* derivation sha256 (hex64) */
    char *src_hash;   /* clean source hash (SRC_PATH), else NULL */
} PathEntry;

static const char *path_of(const PathEntry *es, int ne, const char *name) {
    for (int i = 0; i < ne; i++)
        if (!strcmp(es[i].p->name, name)) return es[i].path;
    return NULL;
}

static void paths_free(PathEntry *es, int n) {
    for (int i = 0; i < n; i++) { free(es[i].path); free(es[i].hash); free(es[i].src_hash); }
    free(es);
}

static int compute_paths(const PackageSet *ps, struct dl_db *db,
                         char *const *roots, int nroots, const char *store_root,
                         PathEntry **out, int *n_out, char *err, size_t errcap) {
    if (fx_closure_compute(db, ps, roots, nroots, err, errcap) != 0) return -1;
    char **names = NULL; int nn = 0;
    if (fx_closure_names(db, &names, &nn, err, errcap) != 0) return -1;
    Package **ord = NULL; int no = 0;
    if (fx_topo_order(ps, names, nn, &ord, &no, err, errcap) != 0) {
        for (int i = 0; i < nn; i++) free(names[i]); free(names); return -1;
    }
    for (int i = 0; i < nn; i++) free(names[i]); free(names);

    PathEntry *es = calloc((size_t)(no ? no : 1), sizeof *es);
    if (!es) { free(ord); return fx_err(err, errcap, "out of memory"); }
    int rc = 0;
    for (int i = 0; i < no; i++) {
        Package *p = ord[i];
        char **dep_paths = p->ndeps ? malloc((size_t)p->ndeps * sizeof *dep_paths) : NULL;
        if (p->ndeps && !dep_paths) { fx_err(err, errcap, "out of memory"); rc = -1; break; }
        int ok = 1;
        for (int j = 0; j < p->ndeps; j++) {
            dep_paths[j] = (char *)path_of(es, i, p->deps[j]);
            if (!dep_paths[j]) { fx_err(err, errcap, "internal: dep '%s' of '%s' unresolved", p->deps[j], p->name); ok = 0; break; }
        }
        if (ok) {
            char h[65], path[PATH_MAX]; char *src_hash = NULL;
            if (p->src.kind == SRC_PATH) {
                char sh[65];
                if (fx_content_hash_dir(p->src.path, p->excludes, p->nexcludes, sh, err, errcap) != 0) rc = -1;
                else if (!(es[i].src_hash = strdup(sh))) { fx_err(err, errcap, "out of memory"); rc = -1; }
                else src_hash = es[i].src_hash;
            }
            if (rc == 0 && fx_derivation_hash_ex(p, src_hash, dep_paths, p->ndeps, h, err, errcap) == 0) {
                fx_store_path_of(store_root, h, p->name, path, sizeof path);
                es[i].p = p; es[i].hash = strdup(h); es[i].path = strdup(path);
                if (!es[i].hash || !es[i].path) { fx_err(err, errcap, "out of memory"); rc = -1; }
            } else if (rc == 0) rc = -1;
        }
        free(dep_paths);
        if (rc != 0) break;
    }
    free(ord);
    if (rc != 0) { paths_free(es, no); *out = NULL; *n_out = 0; return -1; }
    *out = es; *n_out = no; return 0;
}

/* ─── growable byte buffer ──────────────────────────────────────────────── */

typedef struct { char *d; size_t len, cap; } Buf;

static int buf_init(Buf *b) { b->cap = 4096; b->len = 0; b->d = malloc(b->cap); return b->d ? 0 : -1; }
static int buf_reserve(Buf *b, size_t add) {
    if (b->len + add + 1 <= b->cap) return 0;
    size_t nc = b->cap; while (nc < b->len + add + 1) nc *= 2;
    char *nd = realloc(b->d, nc); if (!nd) return -1; b->d = nd; b->cap = nc; return 0;
}
static int buf_put(Buf *b, const void *p, size_t n) {
    if (buf_reserve(b, n) != 0) return -1; memcpy(b->d + b->len, p, n); b->len += n; return 0;
}
static int buf_str(Buf *b, const char *s) { return buf_put(b, s, strlen(s)); }
static int buf_ch(Buf *b, char c) { return buf_put(b, &c, 1); }
/* u32be length-prefixed string (canonical serialization) */
static int buf_u32(Buf *b, uint32_t v) {
    unsigned char t[4] = { (unsigned char)(v>>24),(unsigned char)(v>>16),(unsigned char)(v>>8),(unsigned char)v };
    return buf_put(b, t, 4);
}
static int buf_lpstr(Buf *b, const char *s) {
    size_t n = strlen(s); if (n > 0xffffffffu) return -1;
    if (buf_u32(b, (uint32_t)n) != 0) return -1;
    return buf_put(b, s, n);
}

/* ─── Dhall string literal escaper (for embedding text into the buildfile) ──
 * Dhall Text literal uses "..." with \" and \\ escapes. */
static int buf_dhall_str(Buf *b, const char *s) {
    if (buf_ch(b, '"') != 0) return -1;
    for (const char *p = s; *p; p++) {
        if (*p == '"' || *p == '\\') { if (buf_ch(b, '\\') != 0) return -1; }
        if (buf_ch(b, *p) != 0) return -1;
    }
    return buf_ch(b, '"');
}

/* ─── helpers ────────────────────────────────────────────────────────────── */

/* basename of a path (final component) */
static const char *base_name(const char *path) {
    const char *s = strrchr(path, '/');
    return s ? s + 1 : path;
}

/* find the store path of a closure package by name */
static const char *store_path_of(const PathEntry *es, int ne, const char *name) {
    return path_of(es, ne, name);
}

/* reconstruct the full on= readiness string from kind + arg, so fx-init can
 * re-parse the on= condition (the argument is otherwise lost between
 * activation and boot). */
static void on_full(FxOnKind k, const char *arg, char *out, size_t cap) {
    switch (k) {
        case FX_ON_ALL:      snprintf(out, cap, "all"); break;
        case FX_ON_UP:       snprintf(out, cap, "up:%s", arg ? arg : ""); break;
        case FX_ON_SOCK_TCP: snprintf(out, cap, "sock:tcp:%s", arg ? arg : ""); break;
        case FX_ON_SOCK_UNIX:snprintf(out, cap, "sock:unix:%s", arg ? arg : ""); break;
        case FX_ON_TIME:     snprintf(out, cap, "time:%s", arg ? arg : ""); break;
        case FX_ON_NET:      snprintf(out, cap, "net"); break;
        default:            snprintf(out, cap, "all"); break;
    }
}

/* ─── etc content renderers ──────────────────────────────────────────────── */

static int render_passwd(Buf *b, const FxConfig *cfg) {
    for (int i = 0; i < cfg->nusers; i++) {
        char line[256];
        snprintf(line, sizeof line, "%s:x:%u:%u::/home/%s:/bin/sh\n",
                 cfg->users[i].name, cfg->users[i].uid, cfg->users[i].uid, cfg->users[i].name);
        if (buf_str(b, line) != 0) return -1;
    }
    return 0;
}

/* group file: primary group per user + each supplementary group claimed by a
 * user, gid = the first claiming user's uid. */
static int render_group(Buf *b, const FxConfig *cfg) {
    for (int i = 0; i < cfg->nusers; i++) {
        char line[256];
        snprintf(line, sizeof line, "%s:x:%u:\n", cfg->users[i].name, cfg->users[i].uid);
        if (buf_str(b, line) != 0) return -1;
    }
    for (int i = 0; i < cfg->nusers; i++) {
        for (int g = 0; g < cfg->users[i].ngroups; g++) {
            const char *gn = cfg->users[i].groups[g];
            int is_user_primary = 0;
            for (int k = 0; k < cfg->nusers; k++)
                if (!strcmp(cfg->users[k].name, gn)) { is_user_primary = 1; break; }
            if (is_user_primary) continue;
            char line[256];
            snprintf(line, sizeof line, "%s:x:%u:\n", gn, cfg->users[i].uid);
            if (buf_str(b, line) != 0) return -1;
        }
    }
    return 0;
}

/* ─── Dhakefile.dhall renderer (artifact-1 template, byte shape) ─────────── */

static int emit_action_header(Buf *b) {
    static const char *hdr =
        "let Action =\n"
        "      < Shell : Text\n"
        "      | Copy : { from : Text, to : Text }\n"
        "      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >\n"
        "      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >\n"
        "      | Touch : Text\n"
        "      | Move : { from : Text, to : Text }\n"
        "      | Symlink : { from : Text, to : Text }\n"
        "      | Chmod : { path : Text, mode : Text }\n"
        "      | Echo : Text\n"
        "      | Env : { key : Text, value : Text }\n"
        "      | Run : { argv : List Text }\n"
        "      >\n\n"
        "let Target = { deps : List Text, phony : Bool, recipe : List Action }\n\n";
    return buf_str(b, hdr);
}

/* (path, content) pair for an /etc file */
typedef struct { char *path; char *content; } EtcItem;
static void etcitem_free(EtcItem *e, int n) {
    for (int i = 0; i < n; i++) { free(e[i].path); free(e[i].content); }
    free(e);
}

/* comparison for sorting EtcItem by path */
static int etcitem_cmp(const void *a, const void *b) {
    const EtcItem *x = a, *y = b; return strcmp(x->path, y->path);
}

/* (name, storedir) pair for a /bin symlink */
typedef struct { char *name; char *storedir; } BinLink;
static void binlink_free(BinLink *bl, int n) {
    for (int i = 0; i < n; i++) { free(bl[i].name); free(bl[i].storedir); }
    free(bl);
}
static int binlink_cmp(const void *a, const void *b) {
    const BinLink *x = a, *y = b; return strcmp(x->name, y->name);
}

static int emit_buildfile(Buf *b, const char *gen_dir,
                          const EtcItem *etc, int netc,
                          const BinLink *bin, int nbin) {
    if (emit_action_header(b) != 0) return -1;
    if (buf_str(b, "let GEN = ") != 0) return -1;
    if (buf_dhall_str(b, gen_dir) != 0) return -1;
    if (buf_str(b, "\n\nin  { default = \"rootfs\"\n    , targets =\n        [ { mapKey = \"dirs\"\n          , mapValue =\n              { deps = [] : List Text\n              , phony = True\n              , recipe =\n                  [ < Mkdir = < Parents = { path = \"/etc\", parents = True } > >\n                  , < Mkdir = < Parents = { path = \"/bin\", parents = True } > >\n                  , < Mkdir = < Parents = { path = \"/run\", parents = True } > >\n                  , < Mkdir = < Parents = { path = \"/run/fx\", parents = True } > >\n                  ]\n              }\n          }\n") != 0) return -1;

    /* etc target */
    if (buf_str(b, "        , { mapKey = \"etc\"\n          , mapValue =\n              { deps = [ \"dirs\" ]\n              , phony = True\n              , recipe =\n                  [ ") != 0) return -1;
    if (netc == 0) {
        if (buf_str(b, "] : List Action\n") != 0) return -1;
    } else {
        for (int i = 0; i < netc; i++) {
            char from[PATH_MAX], to[PATH_MAX];
            snprintf(from, sizeof from, "%s/etc/%s", gen_dir, etc[i].path);
            snprintf(to, sizeof to, "/etc/%s", etc[i].path);
            if (buf_str(b, "< Copy = { from = ") != 0) return -1;
            if (buf_dhall_str(b, from) != 0) return -1;
            if (buf_str(b, ", to = ") != 0) return -1;
            if (buf_dhall_str(b, to) != 0) return -1;
            if (buf_str(b, " } >\n                  , < Chmod = { path = ") != 0) return -1;
            if (buf_dhall_str(b, to) != 0) return -1;
            if (buf_str(b, ", mode = \"0644\" } >\n                  , ") != 0) return -1;
        }
        /* trim the trailing ", " — rewrite last separator */
        /* We wrote " , " after the final action; replace with "]\n" */
        /* Simplest: rewind 2 chars (the ", ") and close the list. */
        if (b->len >= 2) b->len -= 2;
        if (buf_str(b, " ]\n") != 0) return -1;
    }
    if (buf_str(b, "              }\n          }\n") != 0) return -1;

    /* bin target */
    if (buf_str(b, "        , { mapKey = \"bin\"\n          , mapValue =\n              { deps = [ \"dirs\" ]\n              , phony = True\n              , recipe =\n                  [ ") != 0) return -1;
    if (nbin == 0) {
        if (buf_str(b, "] : List Action\n") != 0) return -1;
    } else {
        for (int i = 0; i < nbin; i++) {
            char to[PATH_MAX];
            snprintf(to, sizeof to, "/bin/%s", bin[i].name);
            if (buf_str(b, "< Rm = < Plain = ") != 0) return -1;
            if (buf_dhall_str(b, to) != 0) return -1;
            if (buf_str(b, " > >\n                  , < Symlink = { from = ") != 0) return -1;
            if (buf_dhall_str(b, bin[i].storedir) != 0) return -1;
            if (buf_str(b, ", to = ") != 0) return -1;
            if (buf_dhall_str(b, to) != 0) return -1;
            if (buf_str(b, " } >\n                  , ") != 0) return -1;
        }
        if (b->len >= 2) b->len -= 2;
        if (buf_str(b, " ]\n") != 0) return -1;
    }
    if (buf_str(b, "              }\n          }\n") != 0) return -1;

    /* rootfs target */
    if (buf_str(b, "        , { mapKey = \"rootfs\"\n          , mapValue =\n              { deps = [ \"etc\", \"bin\" ]\n              , phony = True\n              , recipe = [] : List Action\n              }\n          }\n        ]\n      }\n") != 0) return -1;
    return 0;
}

/* ─── canonical generation serialization -> sha256 ────────────────────────
 *   magic "fxgen-v1\n"
 *   | hostname
 *   | u32be netc, then per file (sorted by path): lpstr path, lpstr content
 *   | u32be nsvc,  then per service (sorted by name):
 *        lpstr name | u32be nargv | per-arg lpstr
 *        lpstr pkg (or "" if none) | lpstr on | lpstr restart
 *        lpstr probe_kind | lpstr probe_arg (or "")
 *   | u32be npaths, then closure store paths sorted (each lpstr) */
static int serialize_generation(Buf *b, const FxConfig *cfg,
                                const EtcItem *etc, int netc,
                                const PathEntry *es, int ne) {
    if (buf_str(b, "fxgen-v1\n") != 0) return -1;
    if (buf_lpstr(b, cfg->hostname) != 0) return -1;
    if (buf_u32(b, (uint32_t)netc) != 0) return -1;
    for (int i = 0; i < netc; i++) {
        if (buf_lpstr(b, etc[i].path) != 0) return -1;
        if (buf_lpstr(b, etc[i].content) != 0) return -1;
    }
    if (buf_u32(b, (uint32_t)cfg->nservices) != 0) return -1;
    /* services sorted by name */
    const FxService **sv = calloc((size_t)(cfg->nservices ? cfg->nservices : 1), sizeof *sv);
    if (!sv) return -1;
    for (int i = 0; i < cfg->nservices; i++) sv[i] = &cfg->services[i];
    /* simple insertion sort by name */
    for (int i = 1; i < cfg->nservices; i++) {
        const FxService *t = sv[i]; int j = i;
        while (j > 0 && strcmp(sv[j-1]->name, t->name) > 0) { sv[j] = sv[j-1]; j--; }
        sv[j] = t;
    }
    for (int i = 0; i < cfg->nservices; i++) {
        const FxService *s = sv[i];
        if (buf_lpstr(b, s->name) != 0) { free(sv); return -1; }
        if (buf_u32(b, (uint32_t)s->nargv) != 0) { free(sv); return -1; }
        for (int a = 0; a < s->nargv; a++) if (buf_lpstr(b, s->argv[a]) != 0) { free(sv); return -1; }
        if (buf_lpstr(b, s->pkg ? s->pkg : "") != 0) { free(sv); return -1; }
        const char *on; switch (s->on_kind) {
            case FX_ON_ALL: on="all"; break; case FX_ON_UP: on="up"; break;
            case FX_ON_SOCK_TCP: on="sock:tcp"; break; case FX_ON_SOCK_UNIX: on="sock:unix"; break;
            case FX_ON_TIME: on="time"; break; case FX_ON_NET: on="net"; break; default: on="?"; break;
        }
        if (buf_lpstr(b, on) != 0) { free(sv); return -1; }
        if (buf_lpstr(b, s->on_arg ? s->on_arg : "") != 0) { free(sv); return -1; }
        const char *rs; switch (s->restart) {
            case FX_RESTART_ALWAYS: rs="always"; break; case FX_RESTART_ON_FAILURE: rs="on-failure"; break;
            case FX_RESTART_NEVER: rs="never"; break; default: rs="?"; break;
        }
        if (buf_lpstr(b, rs) != 0) { free(sv); return -1; }
        if (buf_u32(b, s->backoff_ms) != 0) { free(sv); return -1; }
        const char *pk; switch (s->probe_kind) {
            case FX_PROBE_NONE: pk=""; break; case FX_PROBE_TCP: pk="tcp"; break;
            case FX_PROBE_UNIX: pk="unix"; break; case FX_PROBE_FILE: pk="file"; break; default: pk="?"; break;
        }
        if (buf_lpstr(b, pk) != 0) { free(sv); return -1; }
        if (buf_lpstr(b, s->probe_arg ? s->probe_arg : "") != 0) { free(sv); return -1; }
    }
    free(sv);
    /* closure store paths sorted */
    char **paths = calloc((size_t)(ne ? ne : 1), sizeof(char *));
    if (!paths) return -1;
    for (int i = 0; i < ne; i++) paths[i] = es[i].path;
    for (int i = 1; i < ne; i++) {
        char *t = paths[i]; int j = i;
        while (j > 0 && strcmp(paths[j-1], t) > 0) { paths[j] = paths[j-1]; j--; }
        paths[j] = t;
    }
    if (buf_u32(b, (uint32_t)ne) != 0) { free(paths); return -1; }
    for (int i = 0; i < ne; i++) if (buf_lpstr(b, paths[i]) != 0) { free(paths); return -1; }
    free(paths);
    return 0;
}

/* ─── write a file with mkdir -p of its parent ──────────────────────────── */
static int write_file_p(const char *path, const char *content, size_t len, char *err, size_t errcap) {
    char dir[PATH_MAX]; size_t pl = strlen(path);
    if (pl >= sizeof dir) return fx_err(err, errcap, "path too long: %s", path);
    memcpy(dir, path, pl+1);
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
        /* mkdir -p */
        for (char *q = dir + 1; *q; q++) {
            if (*q == '/') { *q = '\0'; if (mkdir(dir, 0755) != 0 && errno != EEXIST) { *q = '/'; return fx_err(err, errcap, "mkdir %s: %s", dir, strerror(errno)); } *q = '/'; }
        }
        if (mkdir(dir, 0755) != 0 && errno != EEXIST) return fx_err(err, errcap, "mkdir %s: %s", dir, strerror(errno));
    }
    FILE *f = fopen(path, "wb");
    if (!f) return fx_err(err, errcap, "open %s: %s", path, strerror(errno));
    if (fwrite(content, 1, len, f) != len) { fclose(f); return fx_err(err, errcap, "write %s: %s", path, strerror(errno)); }
    if (fclose(f) != 0) return fx_err(err, errcap, "close %s: %s", path, strerror(errno));
    return 0;
}

/* ─── fact writer (declare + txn_add_fact) ─────────────────────────────── */
static int declare(struct dl_db *db, const char *rel, uint8_t arity, char *err, size_t errcap) {
    /* dl_declare_relation is idempotent: re-declaring with the same arity is a
     * no-op returning 0; an arity mismatch or arity>8 returns -1. */
    if (dl_declare_relation(db, rel, arity) != 0)
        return fx_err(err, errcap, "declare %s/%u failed", rel, arity);
    return 0;
}

static int add_fact(struct dl_db *db, const char *rel, const uint32_t *cols, uint8_t arity) {
    /* we intern strings outside and pass sym ids; ints as raw u32 */
    return dl_txn_add_fact(db, rel, cols, arity);
}

/* delete-all existing tuples of `rel` (collect then delete — safe vs the live
 * DAFSA cursor).  Must be called inside an open txn.  Used to make each
 * activation's snapshot self-consistent (only THIS activation's generation/
 * svc facts) instead of accumulating stale services across activations. */
static int clear_rel(struct dl_db *db, const char *rel, uint8_t arity) {
    dl_iter *it = dl_iter_open(db, rel, NULL, 0);
    if (!it) return 0;
    if (dl_iter_arity(it) != arity) { dl_iter_close(it); return -1; }
    size_t cap = 64, n = 0;
    uint32_t *all = malloc(cap * arity * sizeof *all);
    if (!all) { dl_iter_close(it); return -1; }
    uint32_t row[8];
    while (dl_iter_next(it, row) == 1) {
        if (n >= cap) {
            cap *= 2;
            uint32_t *na = realloc(all, cap * arity * sizeof *all);
            if (!na) { free(all); dl_iter_close(it); return -1; }
            all = na;
        }
        memcpy(all + n * arity, row, arity * sizeof *all);
        n++;
    }
    dl_iter_close(it);
    for (size_t i = 0; i < n; i++)
        dl_txn_delete_fact(db, rel, all + i * arity, arity);
    free(all);
    return 0;
}

/* ─── main activation flow ─────────────────────────────────────────────── */

int main(int argc, char **argv) {
    const char *store_root = NULL, *config_path = NULL, *pkgset_path = NULL;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--store")) { if (++i >= argc) { fprintf(stderr, "fx-activate: --store requires a dir\n"); return 2; } store_root = argv[i]; }
        else if (!strncmp(a, "--store=", 8)) store_root = a + 8;
        else if (!strcmp(a, "--config")) { if (++i >= argc) { fprintf(stderr, "fx-activate: --config requires a path\n"); return 2; } config_path = argv[i]; }
        else if (!strncmp(a, "--config=", 9)) config_path = a + 9;
        else if (!strcmp(a, "--package-set")) { if (++i >= argc) { fprintf(stderr, "fx-activate: --package-set requires a path\n"); return 2; } pkgset_path = argv[i]; }
        else if (!strncmp(a, "--package-set=", 14)) pkgset_path = a + 14;
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(stdout); return 0; }
        else { fprintf(stderr, "fx-activate: unknown arg '%s'\n\n", a); usage(stderr); return 2; }
    }
    if (!store_root) store_root = DEFAULT_STORE_ROOT;
    if (!config_path) config_path = DEFAULT_CONFIG;
    if (!pkgset_path) pkgset_path = DEFAULT_PKGSET;

    char err[ERR_CAP];

    PackageSet ps;
    if (fx_packageset_load(&ps, pkgset_path, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: %s\n", err); return 1;
    }
    FxConfig cfg;
    if (fx_config_load(&cfg, config_path, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: %s\n", err); fx_packageset_free(&ps); return 1;
    }

    FxStore *s = fx_store_open(store_root, err, sizeof err);
    if (!s) { fprintf(stderr, "fx-activate: %s\n", err); fx_config_free(&cfg); fx_packageset_free(&ps); return 1; }
    struct dl_db *db = fx_store_db(s);

    PathEntry *es = NULL; int ne = 0;
    if (compute_paths(&ps, db, cfg.packages, cfg.npackages, store_root, &es, &ne, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: %s\n", err); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    /* verify every closure package is built (store fact + dir), require the
     * tool packages present in the closure */
    int missing = 0;
    Buf miss; buf_init(&miss);
    for (int i = 0; i < ne; i++) {
        struct stat st;
        if (stat(es[i].path, &st) != 0 || !S_ISDIR(st.st_mode)) {
            buf_str(&miss, "  "); buf_str(&miss, es[i].p->name); buf_ch(&miss, '\n');
            missing++;
        }
    }
    if (missing > 0) {
        fprintf(stderr, "fx-activate: %d closure package(s) not built (run 'fxstore build'):\n%.*s",
                missing, (int)miss.len, miss.d);
        free(miss.d); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }
    free(miss.d);

    const char *need_tools[] = { "dhake", "fx-init", "fxctl", "fx-activate" };
    for (size_t i = 0; i < sizeof need_tools/sizeof need_tools[0]; i++) {
        if (!store_path_of(es, ne, need_tools[i])) {
            fprintf(stderr, "fx-activate: required package '%s' not in the closure "
                            "(add it to config.packages)\n", need_tools[i]);
            paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
    }
    const char *dhake_path = store_path_of(es, ne, "dhake");
    char dhake_bin[PATH_MAX]; snprintf(dhake_bin, sizeof dhake_bin, "%s/dhake.com", dhake_path);

    /* collect /etc items: hostname, passwd, group, then extraEtc (sorted) */
    int netc = 3 + cfg.nextra_etc;
    EtcItem *etc = calloc((size_t)(netc ? netc : 1), sizeof *etc);
    if (!etc) { fprintf(stderr, "fx-activate: out of memory\n"); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1; }
    int ni = 0;
    etc[ni].path = strdup("hostname"); etc[ni].content = strdup(cfg.hostname); ni++;
    Buf passwd; buf_init(&passwd); render_passwd(&passwd, &cfg);
    etc[ni].path = strdup("passwd"); etc[ni].content = passwd.d; passwd.d = NULL; ni++;
    Buf group; buf_init(&group); render_group(&group, &cfg);
    etc[ni].path = strdup("group"); etc[ni].content = group.d; group.d = NULL; ni++;
    for (int i = 0; i < cfg.nextra_etc; i++) {
        etc[ni].path = strdup(cfg.extra_etc[i].path);
        etc[ni].content = strdup(cfg.extra_etc[i].content);
        ni++;
    }
    qsort(etc, netc, sizeof *etc, etcitem_cmp);

    /* collect /bin symlinks: init, fxctl, dhake, fx-activate, + one per service pkg */
    int nbin = 4;
    for (int i = 0; i < cfg.nservices; i++) if (cfg.services[i].pkg) nbin++;
    BinLink *bin = calloc((size_t)(nbin ? nbin : 1), sizeof *bin);
    if (!bin) { fprintf(stderr, "fx-activate: out of memory\n"); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1; }
    int bi = 0;
    const char *initp = store_path_of(es, ne, "fx-init");
    bin[bi].name = strdup("init"); bin[bi].storedir = strdup(initp); bi++;
    bin[bi].name = strdup("fxctl"); bin[bi].storedir = strdup(store_path_of(es, ne, "fxctl")); bi++;
    bin[bi].name = strdup("dhake"); bin[bi].storedir = strdup(dhake_path); bi++;
    bin[bi].name = strdup("fx-activate"); bin[bi].storedir = strdup(store_path_of(es, ne, "fx-activate")); bi++;
    for (int i = 0; i < cfg.nservices; i++) {
        FxService *sv = &cfg.services[i];
        if (!sv->pkg) continue;
        const char *p = store_path_of(es, ne, sv->pkg);
        if (!p) {
            fprintf(stderr, "fx-activate: service '%s' pkg '%s' not in the closure\n", sv->name, sv->pkg);
            binlink_free(bin, bi); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
        Package *pk = fx_find_package(&ps, sv->pkg);
        bin[bi].name = strdup(base_name(pk->target)); bin[bi].storedir = strdup(p); bi++;
    }
    qsort(bin, nbin, sizeof *bin, binlink_cmp);

    /* canonical serialization -> gen hash */
    Buf ser; buf_init(&ser);
    if (serialize_generation(&ser, &cfg, etc, netc, es, ne) != 0) {
        fprintf(stderr, "fx-activate: serialization failed\n");
        binlink_free(bin, nbin); etcitem_free(etc, netc); free(ser.d); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }
    char genhash[65];
    sha256_hex(ser.d, ser.len, genhash);
    free(ser.d);

    char gen_dir[PATH_MAX];
    snprintf(gen_dir, sizeof gen_dir, "%s/%s-system-generation", store_root, genhash);

    /* adopt if exists; otherwise write to <root>.build/<pid>-gen then rename */
    struct stat gst;
    int existing = (stat(gen_dir, &gst) == 0 && S_ISDIR(gst.st_mode));
    if (!existing) {
        char scratch[PATH_MAX];
        snprintf(scratch, sizeof scratch, "%s.build/%d-gen", store_root, (int)getpid());
        /* mkdir -p the scratch etc dir */
        char ed[PATH_MAX]; snprintf(ed, sizeof ed, "%s/etc", scratch);
        if (mkdir(scratch, 0755) != 0 && errno != EEXIST) {
            fprintf(stderr, "fx-activate: mkdir %s: %s\n", scratch, strerror(errno));
            binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
        if (mkdir(ed, 0755) != 0 && errno != EEXIST) {
            fprintf(stderr, "fx-activate: mkdir %s: %s\n", ed, strerror(errno));
            binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
        /* write etc files */
        for (int i = 0; i < netc; i++) {
            char p[PATH_MAX]; snprintf(p, sizeof p, "%s/etc/%s", scratch, etc[i].path);
            if (write_file_p(p, etc[i].content, strlen(etc[i].content), err, sizeof err) != 0) {
                fprintf(stderr, "fx-activate: %s\n", err);
                binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
            }
        }
        /* write Dhakefile.dhall */
        Buf bf; buf_init(&bf);
        if (emit_buildfile(&bf, gen_dir, etc, netc, bin, nbin) != 0) {
            fprintf(stderr, "fx-activate: buildfile render failed\n");
            free(bf.d); binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
        char dhakefile[PATH_MAX]; snprintf(dhakefile, sizeof dhakefile, "%s/Dhakefile.dhall", scratch);
        if (write_file_p(dhakefile, bf.d, bf.len, err, sizeof err) != 0) {
            fprintf(stderr, "fx-activate: %s\n", err);
            free(bf.d); binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
        }
        free(bf.d);
        if (rename(scratch, gen_dir) != 0) {
            /* maybe a concurrent activation created it: adopt */
            if (stat(gen_dir, &gst) != 0) {
                fprintf(stderr, "fx-activate: rename %s -> %s: %s\n", scratch, gen_dir, strerror(errno));
                binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
            }
        }
    }

    /* buildfile + dhake absolute paths for the generation fact */
    char buildfile_abs[PATH_MAX]; snprintf(buildfile_abs, sizeof buildfile_abs, "%s/Dhakefile.dhall", gen_dir);

    /* declare + txn: generation facts */
    uint32_t now = (uint32_t)time(NULL);
    if (declare(db, "generation", 4, err, sizeof err) != 0 ||
        declare(db, "svc", 3, err, sizeof err) != 0 ||
        declare(db, "svc_argv", 3, err, sizeof err) != 0 ||
        declare(db, "svc_env", 3, err, sizeof err) != 0 ||
        declare(db, "svc_probe", 3, err, sizeof err) != 0 ||
        declare(db, "svc_bin", 2, err, sizeof err) != 0 ||
        declare(db, "svc_backoff", 2, err, sizeof err) != 0 ||
        declare(db, "user", 3, err, sizeof err) != 0 ||
        declare(db, "tool_fxstore", 1, err, sizeof err) != 0 ||
        declare(db, "boot_grace", 1, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: %s\n", err);
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    if (dl_txn_begin(db) != 0) {
        fprintf(stderr, "fx-activate: dl_txn_begin failed\n");
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    /* clear the previous activation's generation/svc/user facts so each
     * published snapshot is self-consistent (only THIS activation's set).
     * Without this, a re-activation would accumulate stale services and
     * fx-init would boot the union of all past service sets. */
    if (clear_rel(db, "generation", 4) != 0 ||
        clear_rel(db, "svc", 3) != 0 ||
        clear_rel(db, "svc_argv", 3) != 0 ||
        clear_rel(db, "svc_env", 3) != 0 ||
        clear_rel(db, "svc_probe", 3) != 0 ||
        clear_rel(db, "svc_bin", 2) != 0 ||
        clear_rel(db, "svc_backoff", 2) != 0 ||
        clear_rel(db, "user", 3) != 0 ||
        clear_rel(db, "tool_fxstore", 1) != 0 ||
        clear_rel(db, "boot_grace", 1) != 0) {
        fprintf(stderr, "fx-activate: clear old facts failed\n");
        dl_txn_rollback(db);
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    /* generation(genhash, buildfile, dhake, epoch) a4 */
    {
        uint32_t cols[4] = { dl_intern_str(db, genhash), dl_intern_str(db, buildfile_abs),
                             dl_intern_str(db, dhake_bin), now };
        add_fact(db, "generation", cols, 4);
    }
    /* tool_fxstore(path) a1 — record the activator's conventional rootfs path so
     * fx-init can fork fx-activate for re-activations over the control socket.
     * (Relation name kept for plan compatibility; the binary IS fx-activate, the
     *  activation tool moved out of fxstore in the standalone-repo structure.)
     *  The /bin/fx-activate symlink is created by dhake from the bin target. */
    {
        uint32_t cols[1] = { dl_intern_str(db, "/bin/fx-activate") };
        add_fact(db, "tool_fxstore", cols, 1);
    }
    /* boot_grace(ms) a1 — persist the config's bootGraceMs so fx-init honors the
     * per-activation grace timeout (config.dhall's bootGraceMs; default 30000).
     * fx-init cannot read dhall, so the value must reach it via a store fact.
     * Stored as a RAW u32 column (same convention as svc_backoff.backoff_ms). */
    {
        uint32_t cols[1] = { cfg.grace_ms };
        add_fact(db, "boot_grace", cols, 1);
    }
    /* svc facts */
    for (int i = 0; i < cfg.nservices; i++) {
        FxService *sv = &cfg.services[i];
        uint32_t sn = dl_intern_str(db, sv->name);
        char onf[256]; on_full(sv->on_kind, sv->on_arg, onf, sizeof onf);
        const char *rs; switch (sv->restart) {
            case FX_RESTART_ALWAYS: rs="always"; break; case FX_RESTART_ON_FAILURE: rs="on-failure"; break;
            case FX_RESTART_NEVER: rs="never"; break; default: rs="always"; break;
        }
        uint32_t cols[3] = { sn, dl_intern_str(db, onf), dl_intern_str(db, rs) };
        add_fact(db, "svc", cols, 3);
        /* svc_backoff(name, backoff_ms) */
        uint32_t cbk[2] = { sn, sv->backoff_ms };
        add_fact(db, "svc_backoff", cbk, 2);
        /* svc_argv(name, idx, arg) */
        for (int a = 0; a < sv->nargv; a++) {
            uint32_t c[3] = { sn, (uint32_t)a, dl_intern_str(db, sv->argv[a]) };
            add_fact(db, "svc_argv", c, 3);
        }
        /* resolve svc_bin: argv[0] -> store path / target-basename, or absolute */
        char resolved[PATH_MAX];
        if (sv->pkg) {
            const char *p = store_path_of(es, ne, sv->pkg);
            Package *pk = fx_find_package(&ps, sv->pkg);
            snprintf(resolved, sizeof resolved, "%s/%s", p, base_name(pk->target));
        } else {
            snprintf(resolved, sizeof resolved, "%s", sv->argv[0]);
        }
        uint32_t cb[2] = { sn, dl_intern_str(db, resolved) };
        add_fact(db, "svc_bin", cb, 2);
        /* svc_env(name, key, value) */
        for (int e = 0; e < sv->nenv; e++) {
            uint32_t ce[3] = { sn, dl_intern_str(db, sv->env[e].key), dl_intern_str(db, sv->env[e].value) };
            add_fact(db, "svc_env", ce, 3);
        }
        /* svc_probe(name, kind, arg) */
        if (sv->probe_kind != FX_PROBE_NONE) {
            const char *pk; switch (sv->probe_kind) {
                case FX_PROBE_TCP: pk="tcp"; break; case FX_PROBE_UNIX: pk="unix"; break;
                case FX_PROBE_FILE: pk="file"; break; default: pk=""; break;
            }
            uint32_t cp[3] = { sn, dl_intern_str(db, pk), dl_intern_str(db, sv->probe_arg ? sv->probe_arg : "") };
            add_fact(db, "svc_probe", cp, 3);
        }
    }
    /* user facts: user(name, uid, groups_csv) a3 */
    for (int i = 0; i < cfg.nusers; i++) {
        Buf gcsv; buf_init(&gcsv);
        for (int g = 0; g < cfg.users[i].ngroups; g++) {
            if (g) buf_ch(&gcsv, ',');
            buf_str(&gcsv, cfg.users[i].groups[g]);
        }
        uint32_t cols[3] = { dl_intern_str(db, cfg.users[i].name), cfg.users[i].uid,
                             dl_intern_str(db, gcsv.d ? gcsv.d : "") };
        add_fact(db, "user", cols, 3);
        free(gcsv.d);
    }

    if (dl_txn_commit(db) != 0) {
        fprintf(stderr, "fx-activate: dl_txn_commit failed\n");
        dl_txn_rollback(db);
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    if (fx_store_publish(s, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: publish: %s\n", err);
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }
    uint32_t v = 0;
    if (fx_store_current_version(s, &v, err, sizeof err) != 0) {
        fprintf(stderr, "fx-activate: %s\n", err);
        binlink_free(bin, nbin); etcitem_free(etc, netc); paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps); return 1;
    }

    printf("activated %s as version %u; buildfile %s\n", genhash, v, buildfile_abs);

    binlink_free(bin, nbin); etcitem_free(etc, netc);
    paths_free(es, ne); fx_store_close(s); fx_config_free(&cfg); fx_packageset_free(&ps);
    return 0;
}
