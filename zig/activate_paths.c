/* activate_paths.c — unit-5 differential-harness helper.  Loads a package-set
 * and runs the SAME compute_paths flow as fx-activate (fx_closure_compute ->
 * fx_closure_names -> fx_topo_order -> fx_content_hash_dir /
 * fx_derivation_hash_ex -> fx_store_path_of), then prints one store-RELATIVE
 * `<hash>-<name>` per line.  activate_diff.sh pre-creates each printed dir
 * (with a dummy payload) so the closure counts as BUILT — fx-activate only
 * stats dir-ness (fx-activate.c:545).
 *
 * usage: activate_paths --store DIR --package-set PATH ROOT...
 *
 * Built by activate_diff.sh with zig cc, linking the same C core as the C
 * oracle (packageset/derivation/closure/store/build + engine + dafsa +
 * dhallc).  Opening the store takes the process-lifetime exclusive dl lock:
 * run sequentially with the activators.
 */
#include "fxstore.h"
#include "dl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static void die(const char *err) {
    fprintf(stderr, "activate_paths: %s\n", err);
    exit(1);
}

/* incremental PathEntry stand-in: name + derivation hash, topo order */
typedef struct {
    const char *name;
    char hash[65];
    char *path; /* full store path */
} Ent;

static const Ent *ent_of(const Ent *es, int n, const char *name) {
    for (int i = 0; i < n; i++)
        if (!strcmp(es[i].name, name)) return &es[i];
    return NULL;
}

int main(int argc, char **argv) {
    const char *store_root = NULL, *pkgset_path = NULL;
    int first_root = argc;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--store") && i + 1 < argc) store_root = argv[++i];
        else if (!strncmp(argv[i], "--store=", 8)) store_root = argv[i] + 8;
        else if (!strcmp(argv[i], "--package-set") && i + 1 < argc) pkgset_path = argv[++i];
        else if (!strncmp(argv[i], "--package-set=", 14)) pkgset_path = argv[i] + 14;
        else { first_root = i; break; }
    }
    if (!store_root || !pkgset_path || first_root >= argc) {
        fprintf(stderr, "usage: activate_paths --store DIR --package-set PATH ROOT...\n");
        return 2;
    }

    char err[4096];
    PackageSet ps;
    if (fx_packageset_load(&ps, pkgset_path, err, sizeof err) != 0) die(err);
    FxStore *s = fx_store_open(store_root, err, sizeof err);
    if (!s) die(err);
    struct dl_db *db = fx_store_db(s);

    /* the tail of fx-activate's compute_paths (fx-activate.c:101-145) */
    if (fx_closure_compute(db, &ps, (char *const *)&argv[first_root],
                           argc - first_root, err, sizeof err) != 0) die(err);
    char **names = NULL; int nn = 0;
    if (fx_closure_names(db, &names, &nn, err, sizeof err) != 0) die(err);
    Package **ord = NULL; int no = 0;
    if (fx_topo_order(&ps, names, nn, &ord, &no, err, sizeof err) != 0) die(err);
    for (int i = 0; i < nn; i++) free(names[i]);
    free(names);

    Ent *es = calloc((size_t)(no ? no : 1), sizeof *es);
    if (!es) die("out of memory");
    for (int i = 0; i < no; i++) {
        Package *p = ord[i];
        char **dep_paths = p->ndeps ? malloc((size_t)p->ndeps * sizeof *dep_paths) : NULL;
        if (p->ndeps && !dep_paths) die("out of memory");
        for (int j = 0; j < p->ndeps; j++) {
            const Ent *de = ent_of(es, i, p->deps[j]);
            if (!de) die("internal: dep unresolved");
            dep_paths[j] = de->path;
        }
        char h[65];
        char *src_hash = NULL;
        if (p->src.kind == SRC_PATH) {
            char sh[65];
            if (fx_content_hash_dir(p->src.path, p->excludes, p->nexcludes, sh, err, sizeof err) != 0)
                die(err);
            src_hash = strdup(sh);
            if (!src_hash) die("out of memory");
        }
        if (fx_derivation_hash_ex(p, src_hash, dep_paths, p->ndeps, h, err, sizeof err) != 0)
            die(err);
        char path[PATH_MAX];
        fx_store_path_of(store_root, h, p->name, path, sizeof path);
        es[i].name = p->name;
        memcpy(es[i].hash, h, sizeof es[i].hash);
        es[i].path = strdup(path);
        if (!es[i].path) die("out of memory");
        printf("%s-%s\n", h, p->name);
    }
    return 0;
}
