/* config.c — (U-A) evaluate a Dhall config.dhall and walk its normal form into
 * an FxConfig (fx.h).
 *
 * Pipeline mirrors fx_packageset_load (packageset.c) exactly:
 *     read_all -> arena_reset(dhall_arena) -> ImportLoader+push_root
 *     -> parse_source -> infer_type [WARNING-only] -> normalize
 *     -> structural walk (rec_get / term_text_cstr / TmCons chains /
 *        TmUnionLit selected alt / TmConst Natural / TmSome|TmNone).
 *
 * Validation at load: unique service names; non-empty argv; on= grammar
 * (all | up:<svc> | sock:tcp:<port> | sock:unix:<abs-path> | time:<ms> |
 *  net); up:<svc> targets exist; restart in {always,on-failure,never}
 * (default always); uid uniqueness; clean extraEtc paths (relative under
 * etc/, no ..).
 *
 * The term-tree helpers rec_get / term_text_cstr / union_selected /
 * list_length are copied from packageset.c (which copied them from
 * dlp/schema_load.c); the Optional walker handles both TmSome and TmNone
 * (and a TmRecordLit default for the bare absent case is treated as None).
 */
#include "fx.h"
#include "fxstore.h"          /* fx_err static inline helper */
#include "dhall.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ERR_CAP_DEFAULT 2048

/* ─── Term-tree helpers (verbatim from packageset.c) ────────────────────── */

static Term *rec_get(Term *t, const char *label) {
    if (!t || t->tag != TmRecordLit) return NULL;
    for (int i = 0; i < t->as.rec.n; i++)
        if (!strcmp(t->as.rec.fs[i].label, label)) return t->as.rec.fs[i].value;
    return NULL;
}

static char *term_text_cstr(Term *t) {
    if (!t || t->tag != TmText) return NULL;
    size_t len = 0;
    for (TextPart *p = t->as.text; p; p = p->next) {
        if (p->expr) return NULL;          /* stuck interpolation */
        if (p->lit) len += strlen(p->lit);
    }
    char *out = malloc(len + 1);
    if (!out) return NULL;
    char *q = out;
    for (TextPart *p = t->as.text; p; p = p->next)
        if (p->lit) { size_t l = strlen(p->lit); memcpy(q, p->lit, l); q += l; }
    *q = '\0';
    return out;
}

static Field *union_selected(Term *u) {
    if (!u || u->tag != TmUnionLit) return NULL;
    for (int i = 0; i < u->as.uni.n; i++)
        if (u->as.uni.fs[i].value) return &u->as.uni.fs[i];
    return NULL;
}

static int list_length(Term *list) {
    int n = 0;
    for (Term *p = list; p && p->tag == TmCons; p = p->as.cons.tail) n++;
    return n;
}

static char *need_text(Term *rec, const char *label, const char *where,
                       char *err, size_t errcap) {
    Term *f = rec_get(rec, label);
    if (!f) { fx_err(err, errcap, "%s: missing field '%s'", where, label); return NULL; }
    char *s = term_text_cstr(f);
    if (!s) { fx_err(err, errcap, "%s: field '%s' must be Text", where, label); return NULL; }
    return s;
}

/* Extract a Natural literal as a uint32 (rejects > UINT32_MAX and bignums).
 * dhall-c represents small naturals as TmConst with c.kind==C_NAT and
 * .nat (no bnat).  Returns 0/-1. */
static int need_nat(Term *rec, const char *label, const char *where,
                    uint32_t *out, char *err, size_t errcap) {
    Term *f = rec_get(rec, label);
    if (!f) { fx_err(err, errcap, "%s: missing field '%s'", where, label); return -1; }
    if (f->tag != TmConst || f->as.c.kind != C_NAT)
        { fx_err(err, errcap, "%s: field '%s' must be a Natural literal", where, label); return -1; }
    if (f->as.c.bnat)
        { fx_err(err, errcap, "%s: field '%s' exceeds 32-bit Natural range", where, label); return -1; }
    if (f->as.c.nat > UINT32_MAX)
        { fx_err(err, errcap, "%s: field '%s' exceeds 32-bit Natural range", where, label); return -1; }
    *out = (uint32_t)f->as.c.nat;
    return 0;
}

/* Optional field: returns 0 if present-and-set (*out_text/... written), 1 if
 * absent/None (default applies), -1 on a malformed present value. */
static int opt_text(Term *rec, const char *label, char **out_text,
                    char *err, size_t errcap, const char *where) {
    Term *f = rec_get(rec, label);
    if (!f) { *out_text = NULL; return 1; }            /* absent */
    if (f->tag == TmNone) { *out_text = NULL; return 1; }
    if (f->tag == TmSome) f = f->as.some.val;
    char *s = term_text_cstr(f);
    if (!s) { fx_err(err, errcap, "%s: field '%s' must be Optional Text", where, label); return -1; }
    *out_text = s;
    return 0;
}
static int opt_nat(Term *rec, const char *label, uint32_t *out,
                   char *err, size_t errcap, const char *where) {
    Term *f = rec_get(rec, label);
    if (!f) { return 1; }
    if (f->tag == TmNone) return 1;
    if (f->tag == TmSome) f = f->as.some.val;
    if (f->tag != TmConst || f->as.c.kind != C_NAT)
        { fx_err(err, errcap, "%s: field '%s' must be Optional Natural", where, label); return -1; }
    if (f->as.c.bnat || f->as.c.nat > UINT32_MAX)
        { fx_err(err, errcap, "%s: field '%s' exceeds 32-bit Natural range", where, label); return -1; }
    *out = (uint32_t)f->as.c.nat;
    return 0;
}

/* ─── on= grammar parser ────────────────────────────────────────────────── */

static int parse_on(const char *s, FxOnKind *kind, char **arg,
                    char *err, size_t errcap, const char *where) {
    if (!strcmp(s, "all")) { *kind = FX_ON_ALL; *arg = NULL; return 0; }
    if (!strcmp(s, "net")) { *kind = FX_ON_NET; *arg = NULL; return 0; }
    if (!strncmp(s, "up:", 3)) {
        if (!s[3]) { fx_err(err, errcap, "%s: on=up: requires a service name", where); return -1; }
        *kind = FX_ON_UP; *arg = strdup(s + 3);
        if (!*arg) { fx_err(err, errcap, "out of memory"); return -1; }
        return 0;
    }
    if (!strncmp(s, "time:", 5)) {
        const char *v = s + 5;
        if (!*v) { fx_err(err, errcap, "%s: on=time: requires a millisecond count", where); return -1; }
        char *end; unsigned long m = strtoul(v, &end, 10);
        if (*end || m == 0)
            { fx_err(err, errcap, "%s: on=time: '%s' is not a positive integer ms", where, v); return -1; }
        *kind = FX_ON_TIME; *arg = strdup(v);
        if (!*arg) { fx_err(err, errcap, "out of memory"); return -1; }
        return 0;
    }
    if (!strncmp(s, "sock:tcp:", 9)) {
        const char *v = s + 9;
        if (!*v) { fx_err(err, errcap, "%s: on=sock:tcp: requires a port", where); return -1; }
        char *end; unsigned long p = strtoul(v, &end, 10);
        if (*end || p == 0 || p > 65535)
            { fx_err(err, errcap, "%s: on=sock:tcp: '%s' is not a valid port", where, v); return -1; }
        *kind = FX_ON_SOCK_TCP; *arg = strdup(v);
        if (!*arg) { fx_err(err, errcap, "out of memory"); return -1; }
        return 0;
    }
    if (!strncmp(s, "sock:unix:", 10)) {
        const char *v = s + 10;
        if (!*v || v[0] != '/')
            { fx_err(err, errcap, "%s: on=sock:unix: requires an absolute path", where); return -1; }
        *kind = FX_ON_SOCK_UNIX; *arg = strdup(v);
        if (!*arg) { fx_err(err, errcap, "out of memory"); return -1; }
        return 0;
    }
    fx_err(err, errcap, "%s: invalid on= '%s' (expected all | up:<svc> | sock:tcp:<port> | sock:unix:<path> | time:<ms> | net)", where, s);
    return -1;
}

/* ─── Probe union: < Tcp : Natural | Unix : Text | File : Text > ──────────── */

static int map_probe(FxService *svc, Term *u, const char *where,
                     char *err, size_t errcap) {
    svc->probe_kind = FX_PROBE_NONE; svc->probe_arg = NULL;
    if (!u) return 0;
    if (u->tag == TmNone) return 0;
    if (u->tag == TmSome) u = u->as.some.val;
    if (!u || u->tag != TmUnionLit)
        { fx_err(err, errcap, "%s: probe must be < Tcp : Natural | Unix : Text | File : Text >", where); return -1; }
    Field *sel = union_selected(u);
    if (!sel) { fx_err(err, errcap, "%s: malformed probe union", where); return -1; }
    if (!strcmp(sel->label, "Tcp")) {
        if (sel->value->tag != TmConst || sel->value->as.c.kind != C_NAT ||
            sel->value->as.c.bnat || sel->value->as.c.nat > 65535 || sel->value->as.c.nat == 0)
            { fx_err(err, errcap, "%s: probe Tcp requires a Natural port 1..65535", where); return -1; }
        char buf[16]; snprintf(buf, sizeof buf, "%llu", (unsigned long long)sel->value->as.c.nat);
        svc->probe_kind = FX_PROBE_TCP; svc->probe_arg = strdup(buf);
    } else if (!strcmp(sel->label, "Unix")) {
        char *p = term_text_cstr(sel->value);
        if (!p || p[0] != '/') { fx_err(err, errcap, "%s: probe Unix requires an absolute path", where); free(p); return -1; }
        svc->probe_kind = FX_PROBE_UNIX; svc->probe_arg = p;
    } else if (!strcmp(sel->label, "File")) {
        char *p = term_text_cstr(sel->value);
        if (!p || p[0] != '/') { fx_err(err, errcap, "%s: probe File requires an absolute path", where); free(p); return -1; }
        svc->probe_kind = FX_PROBE_FILE; svc->probe_arg = p;
    } else {
        fx_err(err, errcap, "%s: unknown probe alternative '< %s = ... >'", where, sel->label);
        return -1;
    }
    if (!svc->probe_arg) { fx_err(err, errcap, "out of memory"); return -1; }
    return 0;
}

/* ─── env list walker: Optional (List { key : Text, value : Text }) ──────── */

static int map_env(FxService *svc, Term *list, const char *where,
                    char *err, size_t errcap) {
    svc->env = NULL; svc->nenv = 0;
    if (!list) return 0;
    if (list->tag == TmNone) return 0;
    if (list->tag == TmSome) list = list->as.some.val;
    if (list->tag == TmNil) return 0;
    if (list->tag != TmCons)
        { fx_err(err, errcap, "%s: env must be a List { key, value }", where); return -1; }
    int n = list_length(list);
    if (n == 0) return 0;
    svc->env = calloc((size_t)n, sizeof(FxEnv));
    if (!svc->env) { fx_err(err, errcap, "out of memory"); return -1; }
    int i = 0;
    for (Term *q = list; q && q->tag == TmCons; q = q->as.cons.tail) {
        Term *item = q->as.cons.head;
        if (!item || item->tag != TmRecordLit)
            { fx_err(err, errcap, "%s: env entries must be { key, value } records", where); return -1; }
        char *k = need_text(item, "key", where, err, errcap);
        if (!k) return -1;
        char *v = need_text(item, "value", where, err, errcap);
        if (!v) { free(k); return -1; }
        svc->env[i].key = k; svc->env[i].value = v; i++;
    }
    svc->nenv = i;
    return 0;
}

/* ─── Service record walker ──────────────────────────────────────────────── */

static int map_service(FxService *svc, Term *rec, char *err, size_t errcap) {
    memset(svc, 0, sizeof *svc);
    svc->restart = FX_RESTART_ALWAYS;
    svc->backoff_ms = 1000;

    svc->name = need_text(rec, "name", "service", err, errcap);
    if (!svc->name) return -1;
    char where[160]; snprintf(where, sizeof where, "service '%s'", svc->name);

    Term *argv_t = rec_get(rec, "argv");
    if (!argv_t) { fx_err(err, errcap, "%s: missing field 'argv'", where); return -1; }
    if (argv_t->tag != TmNil && argv_t->tag != TmCons)
        { fx_err(err, errcap, "%s: 'argv' must be a List Text", where); return -1; }
    int na = list_length(argv_t);
    if (na == 0) { fx_err(err, errcap, "%s: argv must be non-empty", where); return -1; }
    svc->nargv = na;
    svc->argv = calloc((size_t)(na + 1), sizeof(char *));
    if (!svc->argv) { fx_err(err, errcap, "out of memory"); return -1; }
    int i = 0;
    for (Term *q = argv_t; q && q->tag == TmCons; q = q->as.cons.tail) {
        char *a = term_text_cstr(q->as.cons.head);
        if (!a) { fx_err(err, errcap, "%s: argv elements must be Text", where); return -1; }
        svc->argv[i++] = a;
    }
    svc->argv[na] = NULL;

    if (opt_text(rec, "pkg", &svc->pkg, err, errcap, where) < 0) return -1;

    char *on_s = need_text(rec, "on", where, err, errcap);
    if (!on_s) return -1;
    if (parse_on(on_s, &svc->on_kind, &svc->on_arg, err, errcap, where) != 0)
        { free(on_s); return -1; }
    free(on_s);

    char *rst = NULL;
    if (opt_text(rec, "restart", &rst, err, errcap, where) < 0) return -1;
    if (rst) {
        if (!strcmp(rst, "always")) svc->restart = FX_RESTART_ALWAYS;
        else if (!strcmp(rst, "on-failure")) svc->restart = FX_RESTART_ON_FAILURE;
        else if (!strcmp(rst, "never")) svc->restart = FX_RESTART_NEVER;
        else { fx_err(err, errcap, "%s: restart '%s' not in {always,on-failure,never}", where, rst); free(rst); return -1; }
        free(rst);
    }

    uint32_t bo;
    int r = opt_nat(rec, "backoffMs", &bo, err, errcap, where);
    if (r < 0) return -1;
    if (r == 0) svc->backoff_ms = bo;

    Term *probe_t = rec_get(rec, "probe");
    if (probe_t && map_probe(svc, probe_t, where, err, errcap) != 0) return -1;

    Term *env_t = rec_get(rec, "env");
    if (env_t && map_env(svc, env_t, where, err, errcap) != 0) return -1;

    return 0;
}

/* ─── User record walker ─────────────────────────────────────────────────── */

static int map_user(FxUser *u, Term *rec, char *err, size_t errcap) {
    memset(u, 0, sizeof *u);
    u->name = need_text(rec, "name", "user", err, errcap);
    if (!u->name) return -1;
    char where[160]; snprintf(where, sizeof where, "user '%s'", u->name);
    if (need_nat(rec, "uid", where, &u->uid, err, errcap) != 0) return -1;

    Term *groups = rec_get(rec, "groups");
    if (!groups) { fx_err(err, errcap, "%s: missing field 'groups'", where); return -1; }
    if (groups->tag != TmNil && groups->tag != TmCons)
        { fx_err(err, errcap, "%s: 'groups' must be a List Text", where); return -1; }
    u->ngroups = list_length(groups);
    u->groups = calloc((size_t)(u->ngroups ? u->ngroups + 1 : 1), sizeof(char *));
    if (!u->groups) { fx_err(err, errcap, "out of memory"); return -1; }
    int i = 0;
    for (Term *q = groups; q && q->tag == TmCons; q = q->as.cons.tail) {
        char *g = term_text_cstr(q->as.cons.head);
        if (!g) { fx_err(err, errcap, "%s: group names must be Text", where); return -1; }
        u->groups[i++] = g;
    }
    return 0;
}

/* ─── extraEtc: Optional (List { path, content }) ──────────────────────── */

static int map_extra_etc(FxConfig *cfg, Term *list, char *err, size_t errcap) {
    cfg->extra_etc = NULL; cfg->nextra_etc = 0;
    if (!list) return 0;
    if (list->tag == TmNone) return 0;
    if (list->tag == TmSome) list = list->as.some.val;
    if (list->tag == TmNil) return 0;
    if (list->tag != TmCons)
        { fx_err(err, errcap, "extraEtc must be a List { path, content }"); return -1; }
    int n = list_length(list);
    cfg->extra_etc = calloc((size_t)(n ? n : 1), sizeof(FxEtcFile));
    if (!cfg->extra_etc) { fx_err(err, errcap, "out of memory"); return -1; }
    int i = 0;
    for (Term *q = list; q && q->tag == TmCons; q = q->as.cons.tail) {
        Term *item = q->as.cons.head;
        if (!item || item->tag != TmRecordLit)
            { fx_err(err, errcap, "extraEtc entries must be { path, content } records"); return -1; }
        char *p = need_text(item, "path", "extraEtc", err, errcap);
        if (!p) return -1;
        /* clean relative path under etc/, no .. */
        if (p[0] == '/' || strstr(p, "..") || !strcmp(p, ".") || !strcmp(p, "") ||
            strstr(p, "//") || p[strlen(p)-1] == '/') {
            fx_err(err, errcap, "extraEtc path '%s' must be a clean relative path under etc/", p);
            free(p); return -1;
        }
        char *c = need_text(item, "content", "extraEtc", err, errcap);
        if (!c) { free(p); return -1; }
        cfg->extra_etc[i].path = p; cfg->extra_etc[i].content = c; i++;
    }
    cfg->nextra_etc = i;
    return 0;
}

/* ─── Validation pass (cross-field) ──────────────────────────────────────── */

static int validate(FxConfig *cfg, char *err, size_t errcap) {
    /* unique service names + up:<svc> targets exist */
    for (int i = 0; i < cfg->nservices; i++) {
        for (int j = 0; j < i; j++) {
            if (!strcmp(cfg->services[i].name, cfg->services[j].name)) {
                fx_err(err, errcap, "duplicate service name '%s'", cfg->services[i].name);
                return -1;
            }
        }
        FxService *s = &cfg->services[i];
        if (s->on_kind == FX_ON_UP) {
            int found = 0;
            for (int k = 0; k < cfg->nservices; k++)
                if (!strcmp(cfg->services[k].name, s->on_arg)) { found = 1; break; }
            if (!found) {
                fx_err(err, errcap, "service '%s': on=up:'%s' references an unknown service",
                       s->name, s->on_arg);
                return -1;
            }
        }
    }
    /* unique uids */
    for (int i = 0; i < cfg->nusers; i++)
        for (int j = 0; j < i; j++)
            if (cfg->users[i].uid == cfg->users[j].uid) {
                fx_err(err, errcap, "duplicate uid %u (users '%s' and '%s')",
                       cfg->users[i].uid, cfg->users[j].name, cfg->users[i].name);
                return -1;
            }
    return 0;
}

/* ─── Structural walk ─────────────────────────────────────────────────────── */

static int build_config(FxConfig *out, Term *nf, char *err, size_t errcap) {
    memset(out, 0, sizeof *out);
    out->grace_ms = 30000;
    if (!nf || nf->tag != TmRecordLit)
        { fx_err(err, errcap, "config must be a record { hostname, packages, users, services, ... }"); return -1; }

    out->hostname = need_text(nf, "hostname", "config", err, errcap);
    if (!out->hostname) return -1;

    Term *pkgs = rec_get(nf, "packages");
    if (!pkgs) { fx_err(err, errcap, "config missing 'packages'"); return -1; }
    if (pkgs->tag != TmNil && pkgs->tag != TmCons)
        { fx_err(err, errcap, "config 'packages' must be a List Text"); return -1; }
    out->npackages = list_length(pkgs);
    out->packages = calloc((size_t)(out->npackages ? out->npackages + 1 : 1), sizeof(char *));
    if (!out->packages) { fx_err(err, errcap, "out of memory"); return -1; }
    int i = 0;
    for (Term *q = pkgs; q && q->tag == TmCons; q = q->as.cons.tail) {
        char *p = term_text_cstr(q->as.cons.head);
        if (!p) { fx_err(err, errcap, "config: package names must be Text"); return -1; }
        out->packages[i++] = p;
    }

    Term *users = rec_get(nf, "users");
    if (!users) { fx_err(err, errcap, "config missing 'users'"); return -1; }
    if (users->tag != TmNil && users->tag != TmCons)
        { fx_err(err, errcap, "config 'users' must be a List User"); return -1; }
    out->nusers = list_length(users);
    out->users = calloc((size_t)(out->nusers ? out->nusers : 1), sizeof(FxUser));
    if (!out->users) { fx_err(err, errcap, "out of memory"); return -1; }
    i = 0;
    for (Term *q = users; q && q->tag == TmCons; q = q->as.cons.tail) {
        if (map_user(&out->users[i++], q->as.cons.head, err, errcap) != 0) return -1;
    }

    Term *svcs = rec_get(nf, "services");
    if (!svcs) { fx_err(err, errcap, "config missing 'services'"); return -1; }
    if (svcs->tag != TmNil && svcs->tag != TmCons)
        { fx_err(err, errcap, "config 'services' must be a List Service"); return -1; }
    out->nservices = list_length(svcs);
    out->services = calloc((size_t)(out->nservices ? out->nservices : 1), sizeof(FxService));
    if (!out->services) { fx_err(err, errcap, "out of memory"); return -1; }
    i = 0;
    for (Term *q = svcs; q && q->tag == TmCons; q = q->as.cons.tail) {
        if (map_service(&out->services[i++], q->as.cons.head, err, errcap) != 0) return -1;
    }

    Term *etc = rec_get(nf, "extraEtc");
    if (etc && map_extra_etc(out, etc, err, errcap) != 0) return -1;

    uint32_t g;
    int r = opt_nat(nf, "bootGraceMs", &g, err, errcap, "config");
    if (r < 0) return -1;
    if (r == 0) out->grace_ms = g;

    return validate(out, err, errcap);
}

/* ─── Evaluation pipeline (fx_packageset_load pattern) ──────────────────── */

static char *read_all(FILE *f) {
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (len == cap) { cap *= 2; char *nb = realloc(buf, cap); if (!nb) { free(buf); return NULL; } buf = nb; }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0) break;
    }
    buf[len] = '\0';
    return buf;
}

int fx_config_load(FxConfig *out, const char *path, char *err, size_t errcap) {
    if (err && errcap > 0) err[0] = '\0';
    FILE *in = fopen(path, "rb");
    if (!in) return fx_err(err, errcap, "cannot open config '%s': %s", path, strerror(errno));
    char *src = read_all(in);
    fclose(in);
    if (!src) return fx_err(err, errcap, "out of memory reading '%s'", path);

    if (!dhall_arena) dhall_arena = arena_new();
    arena_reset(dhall_arena);

    ImportLoader *loader = import_loader_new();
    import_loader_push_root(loader, path);

    Parser p; memset(&p, 0, sizeof p); p.loader = loader;
    DhallError derr; dhall_error_clear(&derr);

    Term *t = parse_source(&p, src, path, &derr);
    free(src);
    if (!t) {
        snprintf(err, errcap, "config parse error: %s", derr.msg);
        import_loader_free(loader);
        return -1;
    }

    Term *ty = infer_type(&p, t, &derr);
    if (!ty) {
        fprintf(stderr,
                "fx: warning: config does not typecheck (structural walk continues):\n  %s\n",
                derr.msg);
    }

    normalize_clear_error();
    Term *nf = normalize(t);
    if (normalize_has_error()) {
        derr = *normalize_get_error();
        snprintf(err, errcap, "config normalize error: %s", derr.msg);
        import_loader_free(loader);
        return -1;
    }
    import_loader_free(loader);

    if (build_config(out, nf, err, errcap ? errcap : ERR_CAP_DEFAULT) != 0)
        return -1;
    return 0;
}

void fx_config_free(FxConfig *c) {
    if (!c) return;
    free(c->hostname);
    if (c->packages) { for (int i = 0; i < c->npackages; i++) free(c->packages[i]); free(c->packages); }
    if (c->users) {
        for (int i = 0; i < c->nusers; i++) {
            free(c->users[i].name);
            if (c->users[i].groups) { for (int j = 0; j < c->users[i].ngroups; j++) free(c->users[i].groups[j]); free(c->users[i].groups); }
        }
        free(c->users);
    }
    if (c->services) {
        for (int i = 0; i < c->nservices; i++) {
            FxService *s = &c->services[i];
            free(s->name);
            if (s->argv) { for (int j = 0; j < s->nargv; j++) free(s->argv[j]); free(s->argv); }
            free(s->pkg);
            free(s->on_arg);
            free(s->probe_arg);
            if (s->env) { for (int j = 0; j < s->nenv; j++) { free(s->env[j].key); free(s->env[j].value); } free(s->env); }
        }
        free(c->services);
    }
    if (c->extra_etc) {
        for (int i = 0; i < c->nextra_etc; i++) { free(c->extra_etc[i].path); free(c->extra_etc[i].content); }
        free(c->extra_etc);
    }
    memset(c, 0, sizeof *c);
}
