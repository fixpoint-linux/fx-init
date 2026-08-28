/* activate_facts.c — unit-5 differential-harness helper: open a store and
 * dump the 10 M4 relations fx-activate maintains (generation, svc, svc_argv,
 * svc_env, svc_probe, svc_bin, svc_backoff, user, tool_fxstore, boot_grace)
 * plus the published snapshot versions + CURRENT, as SORTED lines with sym
 * columns resolved via dl_intern_str_of.  Raw-u32 columns (epoch, uid, idx,
 * backoff_ms, grace_ms) print numerically; activate_diff.sh sed-normalizes
 * the generation epoch (C and Zig run seconds apart).
 *
 * Must run AFTER the activator exits: dl_open holds a process-lifetime
 * exclusive fcntl lock, so the dump opens its own store handle only once the
 * writer is gone.
 *
 * usage: activate_facts --store DIR
 */
#include "fxstore.h"
#include "dl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* sym_mask bit i set = column i is an interned symbol; else raw u32 */
typedef struct {
    const char *rel;
    int arity;
    unsigned sym_mask;
} RelSpec;

static const RelSpec rels[] = {
    { "generation",   4, 0x7 }, /* (genhash, buildfile, dhake, epoch-raw)   */
    { "svc",          3, 0x7 }, /* (name, on, restart)                      */
    { "svc_argv",     3, 0x5 }, /* (name, idx-raw, arg)                     */
    { "svc_env",      3, 0x7 }, /* (name, key, value)                       */
    { "svc_probe",    3, 0x7 }, /* (name, kind, arg)                        */
    { "svc_bin",      2, 0x3 }, /* (name, path)                             */
    { "svc_backoff",  2, 0x1 }, /* (name, backoff_ms-raw)                   */
    { "user",         3, 0x5 }, /* (name, uid-raw, groups_csv)              */
    { "tool_fxstore", 1, 0x1 }, /* (path)                                   */
    { "boot_grace",   1, 0x0 }, /* (grace_ms-raw)                           */
};

static char **lines = NULL;
static size_t nlines = 0, caplines = 0;

static void add_line(char *l) {
    if (nlines == caplines) {
        caplines = caplines ? caplines * 2 : 256;
        lines = realloc(lines, caplines * sizeof *lines);
        if (!lines) { fprintf(stderr, "activate_facts: out of memory\n"); exit(1); }
    }
    lines[nlines++] = l;
}

static void dump_rel(struct dl_db *db, const RelSpec *r) {
    dl_iter *it = dl_iter_open(db, r->rel, NULL, 0);
    if (!it) return; /* undeclared/empty */
    if (dl_iter_arity(it) != (uint8_t)r->arity) {
        fprintf(stderr, "activate_facts: arity mismatch on %s\n", r->rel);
        exit(1);
    }
    uint32_t row[8];
    while (dl_iter_next(it, row) == 1) {
        char *l = malloc(4096);
        if (!l) { fprintf(stderr, "activate_facts: out of memory\n"); exit(1); }
        size_t off = (size_t)snprintf(l, 4096, "%s", r->rel);
        for (int c = 0; c < r->arity; c++) {
            if (r->sym_mask & (1u << c)) {
                const char *s = dl_intern_str_of(db, row[c]);
                off += (size_t)snprintf(l + off, 4096 - off, " %s", s ? s : "<sym?>");
            } else {
                off += (size_t)snprintf(l + off, 4096 - off, " %u", row[c]);
            }
        }
        add_line(l);
    }
    dl_iter_close(it);
}

static int cmp_lines(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv) {
    const char *store_root = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) store_root = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) store_root = argv[i] + 8;
    }
    if (!store_root) {
        fprintf(stderr, "usage: activate_facts --store DIR\n");
        return 2;
    }

    char err[4096];
    FxStore *s = fx_store_open(store_root, err, sizeof err);
    if (!s) { fprintf(stderr, "activate_facts: %s\n", err); return 1; }
    struct dl_db *db = fx_store_db(s);

    for (size_t i = 0; i < sizeof rels / sizeof rels[0]; i++)
        dump_rel(db, &rels[i]);

    /* published snapshot versions + CURRENT */
    uint32_t vers[256];
    long nv = dl_snapshot_versions(db, vers, 256);
    for (long i = 0; i < nv; i++) {
        char *l = malloc(64);
        if (!l) { fprintf(stderr, "activate_facts: out of memory\n"); exit(1); }
        snprintf(l, 64, "version %u", vers[i]);
        add_line(l);
    }
    uint32_t cur = 0;
    if (fx_store_current_version(s, &cur, err, sizeof err) == 0) {
        char *l = malloc(64);
        if (!l) { fprintf(stderr, "activate_facts: out of memory\n"); exit(1); }
        snprintf(l, 64, "current %u", cur);
        add_line(l);
    }

    qsort(lines, nlines, sizeof *lines, cmp_lines);
    for (size_t i = 0; i < nlines; i++)
        printf("%s\n", lines[i]);
    return 0;
}
