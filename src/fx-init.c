/* fx-init.c — (U-C1) the lean PID1 / supervisor core of fixpoint-linux.
 *
 * A single cosmocc APE binary with one poll(2) event loop.  No Dhall
 * interpreter (build-time eval; reads service facts back out of the store DB).
 * fx-init is the SOLE writer of the volatile runtime DB and the log DB (actor
 * model: dl_open takes a process-lifetime exclusive fcntl lock, so the store
 * DB is opened only transiently for reads/rollback/activate — never held).
 *
 * Boot sequence (pinned order):
 *   1. mkdirs run-dir; signal handlers (SIGTERM/SIGINT->shutdown, SIGCHLD->self-pipe)
 *   2. dl_open(run-dir/state.db) held for life; declare runtime + probe relations
 *   3. fx_log_open(run-dir/log.db) held for life
 *   4. read durable /fx/store/.bootlog (append file: "<version> <status> <epoch>")
 *   5. transient store open: current version v; read generation/svc facts AS-OF
 *      v (or the rolled-back predecessor) into the in-memory Svc table; close
 *   6. boot decision: stale in-progress/failed for current v + a known-good ok
 *      predecessor v'<v exists in dl_snapshot_versions -> fx_store_rollback(v',0)
 *      (roll-forward, monotonic) then re-read facts AS-OF v'
 *   7. append .bootlog (v, in-progress, now)
 *   8. fork+exec dhake -f <buildfile> rootfs; pipe output to the log DB; nonzero
 *      -> append (v,failed) + boot_status(v,failed) + PIN the boot decision so
 *      the START-ONLY grace rule can never flip it to ok, KEEP RUNNING
 *   9. txn: generation_current(v), boot_status(v,in-progress)
 *   10. build on= readiness graph, validate, enter main loop
 *
 * Supervision is START-ONLY: boot-ok is decided at grace-end — every service
 * must have reached STARTED and none may have exited during the grace window
 * (a service that crashes during boot is a start-failure, pinned failed in
 * reap_children; health regressions AFTER boot-ok restart in place and never
 * roll back).  A hang (service never starts) fails via the grace timeout.
 *
 * Link set: src/fx-init.c + fx_probe.c + fx_log.c + store.c + closure.c +
 * build.c + datalog-dafsa + dafsa — NO dhall-c, NO config.c.
 *
 * CLI: fx-init [--store DIR] [--run-dir DIR] [--probe-interval-s N] [--log-cap N]
 *              [--grace-ms N] [--probe-fixture-root DIR]
 * GUARD: runs only if getpid()==1 or env FX_INIT_FORCE=1.
 */
#include "fx.h"            /* enums only: FX_ON_*, FX_PROBE_*, FX_RESTART_* */
#include "fx_reloc.h"      /* store-relocatability: buildfile root rewrite */
#include "fx_probe.h"
#include "fx_log.h"
#include "fxstore.h"
#include "dl.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_STORE    "/fx/store"
#define DEFAULT_RUN      "/run/fx"
#define DEFAULT_PROBE_S  10
#define DEFAULT_LOG_CAP  100000
#define DEFAULT_GRACE_MS 30000
#define REQ_MAX          4096

/* ─── service runtime table ───────────────────────────────────────────────── */

enum { ST_PENDING = 0, ST_STARTING, ST_STARTED, ST_BACKOFF, ST_STOPPED, ST_FAILED };
static const char *ST_NAMES[] = {"pending","starting","started","backoff","stopped","failed"};

typedef struct {
    char   name[128];
    char **argv;            /* NULL-terminated, resolved argv[0] from svc_bin */
    int    nargv;
    char  **env_k, **env_v;
    int    nenv;
    FxOnKind  on_kind;
    char   on_arg[256];
    FxRestart restart;
    uint32_t backoff_ms;
    FxProbeKind probe_kind;
    char   probe_arg[256];
    /* runtime */
    pid_t  pid;             /* 0 = not running */
    int    state;
    int    restarts;
    int    out_fd, err_fd;  /* read ends of stdout/stderr pipes (-1 none) */
    time_t started_at;
    time_t next_start;      /* earliest restart (backoff) */
    uint32_t cur_backoff;
    int    ready;
} Svc;

/* ─── global state ─────────────────────────────────────────────────────────── */

static const char *g_store = DEFAULT_STORE;
static char g_run[256] = DEFAULT_RUN;
static int  g_probe_s   = DEFAULT_PROBE_S;
static uint64_t g_log_cap = DEFAULT_LOG_CAP;
static uint32_t g_grace_ms = DEFAULT_GRACE_MS;
static const char *g_probe_root = NULL;

static struct dl_db *g_rt;          /* runtime DB, held for life */
static struct dl_db *g_log;         /* log DB, held for life */
static Svc *g_svc;
static int  g_nsvc, g_svc_cap;
static uint32_t g_boot_version;     /* version whose facts we booted */
static uint32_t g_current_version;  /* CURRENT (after any rollback) */
static char g_buildfile[1024];
static char g_dhake[1024];
static char g_fxstore[1024] = "/bin/fx-activate";
static char g_hostname[256] = "";
static time_t g_boot_start;
static time_t g_boot_deadline;
static time_t g_next_probe;
static int g_ctrl_fd = -1;
static int g_sigpipe[2] = { -1, -1 };
static volatile sig_atomic_t g_shutdown = 0;
static uint32_t g_txn_id = 1;
static int g_boot_decided = 0;   /* boot_ok evaluated yet */
static int g_boot_failed = 0;

/* ─── helpers ───────────────────────────────────────────────────────────────── */

static uint32_t now_s(void) { return (uint32_t)time(NULL); }

static int mkdirp(const char *path) {
    char buf[1100]; snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1; *p = '/'; }
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static uint32_t isym(struct dl_db *db, const char *s) {
    uint32_t r = dl_intern_str(db, s);
    return r ? r : 1;
}

static Svc *svc_find(const char *name) {
    for (int i = 0; i < g_nsvc; i++) if (!strcmp(g_svc[i].name, name)) return &g_svc[i];
    return NULL;
}

static void log_line(const char *svc, const char *level, const char *msg) {
    if (g_log) fx_log_emit(g_log, now_s(), svc, level, msg);
}

/* parse the full on= string into kind + arg (mirrors config.c grammar) */
static void parse_on(const char *s, FxOnKind *kind, char *arg, size_t cap) {
    if (!strcmp(s, "all")) { *kind = FX_ON_ALL; arg[0] = '\0'; return; }
    if (!strcmp(s, "net")) { *kind = FX_ON_NET; arg[0] = '\0'; return; }
    if (!strncmp(s, "up:", 3)) { *kind = FX_ON_UP; snprintf(arg, cap, "%s", s + 3); return; }
    if (!strncmp(s, "sock:tcp:", 9)) { *kind = FX_ON_SOCK_TCP; snprintf(arg, cap, "%s", s + 9); return; }
    if (!strncmp(s, "sock:unix:", 10)) { *kind = FX_ON_SOCK_UNIX; snprintf(arg, cap, "%s", s + 10); return; }
    if (!strncmp(s, "time:", 5)) { *kind = FX_ON_TIME; snprintf(arg, cap, "%s", s + 5); return; }
    *kind = FX_ON_ALL; arg[0] = '\0';
}

/* ─── runtime DB relations ─────────────────────────────────────────────────── */

static int declare_runtime(struct dl_db *db) {
    if (dl_declare_relation(db, "generation_current", 1) != 0) return -1;
    if (dl_declare_relation(db, "boot_status", 2) != 0) return -1;
    if (dl_declare_relation(db, "service_runtime", 4) != 0) return -1;
    if (dl_declare_relation(db, "ready", 1) != 0) return -1;
    if (dl_declare_relation(db, "control", 3) != 0) return -1;
    if (dl_declare_relation(db, "effect", 3) != 0) return -1;
    if (fx_probe_declare(db) != 0) return -1;
    return 0;
}

/* delete-then-add the single keyed tuple (called inside an open txn) */
static void rt_replace1(const char *rel, uint8_t ar, const uint32_t *key) {
    dl_iter *it = dl_iter_open(g_rt, rel, key, 1);
    if (it) { uint32_t r[8]; while (dl_iter_next(it, r) == 1) dl_txn_delete_fact(g_rt, rel, r, ar); dl_iter_close(it); }
}

static void rt_set_service(Svc *s) {
    uint32_t name = isym(g_rt, s->name);
    rt_replace1("service_runtime", 4, &name);
    const char *st = (s->state >= 0 && s->state <= ST_FAILED) ? ST_NAMES[s->state] : "?";
    uint32_t cols[4] = { name, (uint32_t)(s->pid > 0 ? s->pid : 0), isym(g_rt, st), (uint32_t)s->restarts };
    dl_txn_add_fact(g_rt, "service_runtime", cols, 4);
}

static void rt_set_ready(Svc *s, int ready) {
    uint32_t name = isym(g_rt, s->name);
    rt_replace1("ready", 1, &name);
    if (ready) { uint32_t c[1] = { name }; dl_txn_add_fact(g_rt, "ready", c, 1); }
    s->ready = ready;
}

static void rt_set_boot(uint32_t v, const char *status) {
    rt_replace1("boot_status", 2, &v);
    uint32_t cols[2] = { v, isym(g_rt, status) };
    dl_txn_add_fact(g_rt, "boot_status", cols, 2);
}

static void rt_set_generation_current(uint32_t v) {
    /* a1, exactly one: clear all, then add v */
    dl_iter *it = dl_iter_open(g_rt, "generation_current", NULL, 0);
    if (it) { uint32_t r[1]; while (dl_iter_next(it, r) == 1) dl_txn_delete_fact(g_rt, "generation_current", r, 1); dl_iter_close(it); }
    uint32_t c[1] = { v }; dl_txn_add_fact(g_rt, "generation_current", c, 1);
}

static void rt_control(uint32_t txn, const char *cmd, const char *target) {
    uint32_t c[3] = { txn, isym(g_rt, cmd), isym(g_rt, target) };
    dl_txn_add_fact(g_rt, "control", c, 3);
}
static void rt_effect(uint32_t txn, const char *key, const char *val) {
    uint32_t c[3] = { txn, isym(g_rt, key), isym(g_rt, val) };
    dl_txn_add_fact(g_rt, "effect", c, 3);
}

/* txn wrappers over the runtime DB (sole writer). */
static void rt_txn_begin(void)  { dl_txn_begin(g_rt); }
static int  rt_txn_commit(void) { return dl_txn_commit(g_rt); }

/* ─── durable boot marker: <store>/.bootlog ────────────────────────────────── */

static void bootlog_path(char *out, size_t cap) { snprintf(out, cap, "%s/.bootlog", g_store); }

static void bootlog_append(uint32_t v, const char *status, uint32_t epoch) {
    char p[1100]; bootlog_path(p, sizeof p);
    mkdirp(g_store);
    FILE *f = fopen(p, "a");
    if (!f) return;
    fprintf(f, "%u %s %u\n", v, status, epoch);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
}

static int bootlog_last(uint32_t *v_out, char *status_out, size_t scap) {
    char p[1100]; bootlog_path(p, sizeof p);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    char line[256], sv[64]; uint32_t v = 0; int got = 0;
    while (fgets(line, sizeof line, f)) {
        uint32_t tv; char tsv[64];
        /* skip lifecycle 'shutdown' markers so the last BOOT outcome (which may
         * be in-progress/ok/failed) is what a stale-failed roll-forward check
         * sees — a clean shutdown of a failed boot must not mask the failure.
         * Only record v/sv for a genuine boot-status line. */
        if (sscanf(line, "%u %63s", &tv, tsv) == 2 && strcmp(tsv, "shutdown") != 0) {
            v = tv; memcpy(sv, tsv, sizeof sv); got = 1;
        }
    }
    fclose(f);
    if (got) { *v_out = v; strncpy(status_out, sv, scap - 1); status_out[scap - 1] = '\0'; }
    return got;
}

static int bootlog_newest_ok_below(uint32_t v, uint32_t *out) {
    char p[1100]; bootlog_path(p, sizeof p);
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    char line[256], sv[64]; uint32_t lv = 0, best = 0; int found = 0;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%u %63s", &lv, sv) == 2)
            if (!strcmp(sv, "ok") && lv < v) { if (!found || lv > best) best = lv; found = 1; }
    fclose(f);
    if (found) *out = best;
    return found;
}

static int version_exists(uint32_t v) {
    char err[1024];
    FxStore *s = fx_store_open(g_store, err, sizeof err);
    if (!s) return 0;
    uint32_t vers[256];
    long n = dl_snapshot_versions(fx_store_db(s), vers, 256);
    fx_store_close(s);
    if (n <= 0) return 0;
    for (long i = 0; i < n && i < 256; i++) if (vers[i] == v) return 1;
    return 0;
}

/* ─── transient store reads: generation + svc facts AS-OF a version ─────────── */

typedef struct { uint32_t best_epoch; uint32_t gh, bf, dh; int found; } GenPick;
static int gen_pick_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; GenPick *g = (GenPick *)u;
    if (c[3] >= g->best_epoch) { g->best_epoch = c[3]; g->gh = c[0]; g->bf = c[1]; g->dh = c[2]; g->found = 1; }
    return 0;
}

typedef struct { struct dl_db *db; char *out; size_t cap; int got; } ToolPathCtx;
static int tool_path_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; ToolPathCtx *t = (ToolPathCtx *)u;
    const char *p = dl_intern_str_of(t->db, c[0]);
    if (p && !t->got) { strncpy(t->out, p, t->cap - 1); t->out[t->cap - 1] = '\0'; t->got = 1; }
    return 0;
}

typedef struct { struct dl_db *db; } SvcCtx;
static int svc_name_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; SvcCtx *x = (SvcCtx *)u;
    const char *name = dl_intern_str_of(x->db, c[0]);
    if (!name || svc_find(name)) return 0;
    if (g_nsvc >= g_svc_cap) {
        int nc = g_svc_cap ? g_svc_cap * 2 : 16;
        Svc *ns = realloc(g_svc, (size_t)nc * sizeof *ns);
        if (!ns) return 1;
        g_svc = ns; g_svc_cap = nc;
    }
    Svc *s = &g_svc[g_nsvc++];
    memset(s, 0, sizeof *s);
    strncpy(s->name, name, sizeof s->name - 1);
    s->backoff_ms = 1000; s->restart = FX_RESTART_ALWAYS;
    s->probe_kind = FX_PROBE_NONE; s->state = ST_PENDING; s->out_fd = s->err_fd = -1;
    return 0;
}

typedef struct { struct dl_db *db; uint32_t sn; FxOnKind on_kind; char on_full[256]; FxRestart restart; int got; } SvcMeta;
static int svc_meta_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; SvcMeta *m = (SvcMeta *)u;
    const char *on = dl_intern_str_of(m->db, c[1]);
    const char *rs = dl_intern_str_of(m->db, c[2]);
    if (on) { strncpy(m->on_full, on, sizeof m->on_full - 1); m->on_full[sizeof m->on_full - 1] = '\0'; }
    if (rs) {
        if (!strcmp(rs, "always")) m->restart = FX_RESTART_ALWAYS;
        else if (!strcmp(rs, "on-failure")) m->restart = FX_RESTART_ON_FAILURE;
        else if (!strcmp(rs, "never")) m->restart = FX_RESTART_NEVER;
    }
    m->got = 1; return 0;
}

typedef struct { struct dl_db *db; char **args; int cap; int max_idx; } ArgCtx;
static int svc_argv_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; ArgCtx *a = (ArgCtx *)u;
    uint32_t idx = c[1];
    if ((int)idx >= a->cap) {
        int nc = (int)idx + 8;
        char **na = realloc(a->args, (size_t)nc * sizeof *na);
        if (!na) return 1;
        for (int i = a->cap; i < nc; i++) na[i] = NULL;
        a->args = na; a->cap = nc;
    }
    const char *s = dl_intern_str_of(a->db, c[2]);
    a->args[idx] = s ? strdup(s) : strdup("");
    if ((int)idx > a->max_idx) a->max_idx = (int)idx;
    return 0;
}

typedef struct { struct dl_db *db; char *bin; int got; } BinCtx;
static int svc_bin_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; BinCtx *b = (BinCtx *)u;
    const char *p = dl_intern_str_of(b->db, c[1]);
    if (p) { free(b->bin); b->bin = strdup(p); b->got = 1; }
    return 0;
}

typedef struct { struct dl_db *db; char **k, **v; int n, cap; } EnvCtx;
static int svc_env_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; EnvCtx *e = (EnvCtx *)u;
    if (e->n >= e->cap) {
        int nc = e->cap ? e->cap * 2 : 8;
        char **nk = realloc(e->k, (size_t)nc * sizeof *nk);
        char **nv = realloc(e->v, (size_t)nc * sizeof *nv);
        if (!nk || !nv) { free(nk); free(nv); return 1; }
        e->k = nk; e->v = nv; e->cap = nc;
    }
    const char *kk = dl_intern_str_of(e->db, c[1]);
    const char *vv = dl_intern_str_of(e->db, c[2]);
    e->k[e->n] = strdup(kk ? kk : "");
    e->v[e->n] = strdup(vv ? vv : "");
    e->n++;
    return 0;
}

typedef struct { struct dl_db *db; FxProbeKind kind; char *arg; int got; } ProbeCtx;
static int svc_probe_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; ProbeCtx *p = (ProbeCtx *)u;
    const char *k = dl_intern_str_of(p->db, c[1]);
    const char *a = dl_intern_str_of(p->db, c[2]);
    if (!strcmp(k, "tcp")) p->kind = FX_PROBE_TCP;
    else if (!strcmp(k, "unix")) p->kind = FX_PROBE_UNIX;
    else if (!strcmp(k, "file")) p->kind = FX_PROBE_FILE;
    free(p->arg); p->arg = strdup(a ? a : "");
    p->got = 1; return 0;
}

/* construct sv->argv NULL-terminated from the sparse args[] + optional bin */
static void build_argv(Svc *sv, ArgCtx *ac, const char *bin) {
    int n = ac->max_idx + 1;
    sv->argv = calloc((size_t)n + 1, sizeof(char *));
    for (int i = 0; i < n; i++) {
        if (i == 0 && bin) sv->argv[0] = strdup(bin);
        else sv->argv[i] = strdup(ac->args[i] ? ac->args[i] : "");
    }
    sv->nargv = n;
}

/* svc_backoff(name, backoff_ms) — single tuple expected */
typedef struct { uint32_t v; int got; } BkCtx;
static int backoff_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar;
    BkCtx *b = (BkCtx *)u; b->v = c[1]; b->got = 1; return 0;
}

/* boot_grace(ms) a1 — raw u32; single tuple, the per-activation boot grace. */
typedef struct { uint32_t v; int got; } GraceCtx;
static int grace_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar;
    GraceCtx *g = (GraceCtx *)u; g->v = c[0]; g->got = 1; return 0;
}

/* read all generation + svc facts AS-OF `version`; clears g_svc first. 0/-1. */
static int read_store_facts(uint32_t version) {
    char err[1024];
    FxStore *s = fx_store_open(g_store, err, sizeof err);
    if (!s) { fprintf(stderr, "fx-init: store open: %s\n", err); return -1; }
    struct dl_db *db = fx_store_db(s);

    for (int i = 0; i < g_nsvc; i++) { free(g_svc[i].argv); free(g_svc[i].env_k); free(g_svc[i].env_v); }
    free(g_svc); g_svc = NULL; g_nsvc = 0; g_svc_cap = 0;

    GenPick gp = {0};
    dl_query_version(db, version, "generation", gen_pick_cb, &gp);
    if (!gp.found) { fx_store_close(s); return -1; }
    const char *bf = dl_intern_str_of(db, gp.bf);
    const char *dh = dl_intern_str_of(db, gp.dh);
    if (!bf || !dh) { fx_store_close(s); return -1; }
    /* bf + dh are STORE-RELATIVE (fx-activate records `<genhash>-system-generation/
     * Dhakefile.dhall` and `<hash>-dhake/dhake.com`); resolve against g_store so
     * the paths resolve wherever the store lives at boot (host temp dir at
     * activation time, /fx/store in the chroot, or any other --store root). */
    snprintf(g_buildfile, sizeof g_buildfile, "%s/%s", g_store, bf);
    snprintf(g_dhake, sizeof g_dhake, "%s/%s", g_store, dh);

    ToolPathCtx tp = { db, g_fxstore, sizeof g_fxstore, 0 };
    dl_query_version(db, version, "tool_fxstore", tool_path_cb, &tp);

    /* boot_grace(ms) — override the default grace with the activation's value. */
    GraceCtx gc = {0,0};
    dl_query_version(db, version, "boot_grace", grace_cb, &gc);
    if (gc.got && gc.v > 0) g_grace_ms = gc.v;

    SvcCtx sc = { db };
    dl_query_version(db, version, "svc", svc_name_cb, &sc);

    for (int i = 0; i < g_nsvc; i++) {
        Svc *sv = &g_svc[i];
        uint32_t sn = dl_intern_str(db, sv->name);
        SvcMeta sm; sm.db = db; sm.sn = sn; sm.on_kind = FX_ON_ALL; sm.restart = FX_RESTART_ALWAYS;
        sm.on_full[0] = '\0'; sm.got = 0;
        dl_query_bound_version(db, version, "svc", &sn, 1, svc_meta_cb, &sm);
        sv->restart = sm.restart;
        parse_on(sm.on_full, &sv->on_kind, sv->on_arg, sizeof sv->on_arg);

        ArgCtx ac; ac.db = db; ac.args = NULL; ac.cap = 0; ac.max_idx = -1;
        dl_query_bound_version(db, version, "svc_argv", &sn, 1, svc_argv_cb, &ac);

        BinCtx bc; bc.db = db; bc.bin = NULL; bc.got = 0;
        dl_query_bound_version(db, version, "svc_bin", &sn, 1, svc_bin_cb, &bc);
        /* svc_bin is STORE-RELATIVE for a pkg'd service (`<hash>-<pkg>/<target>`);
         * resolve it against g_store.  A non-pkg'd service's argv[0] is absolute
         * (e.g. /bin/sh) and is passed through unchanged. */
        if (bc.bin && bc.bin[0] != '/') {
            char abs[PATH_MAX];
            snprintf(abs, sizeof abs, "%s/%s", g_store, bc.bin);
            free(bc.bin); bc.bin = strdup(abs);
        }
        build_argv(sv, &ac, bc.bin);
        free(bc.bin);

        /* svc_backoff(name, backoff_ms) */
        BkCtx bkc = {0,0};
        dl_query_bound_version(db, version, "svc_backoff", &sn, 1, backoff_cb, &bkc);
        sv->backoff_ms = bkc.got ? bkc.v : 1000;

        EnvCtx ec; ec.db = db; ec.k = NULL; ec.v = NULL; ec.n = 0; ec.cap = 0;
        dl_query_bound_version(db, version, "svc_env", &sn, 1, svc_env_cb, &ec);
        sv->env_k = ec.k; sv->env_v = ec.v; sv->nenv = ec.n;

        ProbeCtx pc; pc.db = db; pc.kind = FX_PROBE_NONE; pc.arg = NULL; pc.got = 0;
        dl_query_bound_version(db, version, "svc_probe", &sn, 1, svc_probe_cb, &pc);
        sv->probe_kind = pc.kind;
        if (pc.arg) { strncpy(sv->probe_arg, pc.arg, sizeof sv->probe_arg - 1); sv->probe_arg[sizeof sv->probe_arg - 1] = '\0'; free(pc.arg); }

        for (int j = 0; j < ac.cap; j++) free(ac.args[j]);
        free(ac.args);
    }

    fx_store_close(s);
    return 0;
}

/* ─── boot decision + dhake materialization ────────────────────────────────── */

/* returns the version to read facts AS-OF (after possible rollback), and sets
 * g_current_version to the new CURRENT. */
static uint32_t decide_boot_version(void) {
    char err[1024];
    FxStore *s = fx_store_open(g_store, err, sizeof err);
    if (!s) { fprintf(stderr, "fx-init: store open: %s\n", err); return 0; }
    uint32_t v = 0;
    if (fx_store_current_version(s, &v, err, sizeof err) != 0) {
        fprintf(stderr, "fx-init: no current version: %s\n", err);
        fx_store_close(s);
        return 0;
    }
    g_current_version = v;
    fx_store_close(s);

    /* bootlog decision */
    uint32_t lv; char lstatus[64];
    if (bootlog_last(&lv, lstatus, sizeof lstatus) && lv == g_current_version &&
        (!strcmp(lstatus, "in-progress") || !strcmp(lstatus, "failed"))) {
        uint32_t vok;
        if (bootlog_newest_ok_below(g_current_version, &vok) && version_exists(vok)) {
            fprintf(stderr, "fx-init: stale %s for v%u; rolling forward to v%u\n",
                    lstatus, g_current_version, vok);
            char e2[1024];
            FxStore *rs = fx_store_open(g_store, e2, sizeof e2);
            if (rs && fx_store_rollback(rs, vok, 0, e2, sizeof e2) == 0) {
                fx_store_current_version(rs, &g_current_version, e2, sizeof e2);
                log_line("fx-init", "info", "rolled forward to known-good generation");
            }
            if (rs) fx_store_close(rs);
            return vok;  /* read facts AS-OF the good predecessor */
        }
    }
    return g_current_version;
}

/* fork+exec dhake -f buildfile rootfs; pipe stdout/stderr to the log DB;
 * waitpid.  returns dhake exit code (0 ok).
 *
 * The stored buildfile embeds the ACTIVATION-time host store root in its
 * `let GEN = "<host_store>/..."` and every bin Symlink `from`.  At boot the
 * store may live under a different root (chroot: /fx/store, or any --store), so
 * we rewrite that host root to g_store (fx_reloc_rewrite_buildfile) and exec
 * dhake on the rewritten copy under the run dir.  The `to` paths (/etc/...,
 * /bin/..., /run/...) are absolute and never under the store, so they pass
 * through unchanged. */
static int run_dhake(void) {
    if (access(g_dhake, X_OK) != 0) {
        log_line("dhake", "error", "dhake binary not executable");
        return -1;
    }
    /* read the stored buildfile and rewrite its host store root to g_store */
    char bootbf[1100];
    snprintf(bootbf, sizeof bootbf, "%s/Dhakefile.boot.dhall", g_run);
    {
        FILE *f = fopen(g_buildfile, "r");
        if (!f) { log_line("dhake", "error", "cannot open buildfile"); return -1; }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        if (sz < 0) { fclose(f); log_line("dhake", "error", "buildfile stat failed"); return -1; }
        char *text = malloc((size_t)sz + 1);
        if (!text) { fclose(f); log_line("dhake", "error", "oom reading buildfile"); return -1; }
        size_t rd = fread(text, 1, (size_t)sz, f); fclose(f); text[rd] = '\0';
        char *rew = fx_reloc_rewrite_buildfile(text, g_store);
        free(text);
        if (!rew) { log_line("dhake", "error", "buildfile reloc rewrite failed"); return -1; }
        FILE *of = fopen(bootbf, "w");
        if (!of) { free(rew); log_line("dhake", "error", "cannot write boot buildfile"); return -1; }
        size_t wl = strlen(rew);
        if (fwrite(rew, 1, wl, of) != wl) { fclose(of); free(rew); unlink(bootbf); log_line("dhake", "error", "boot buildfile write failed"); return -1; }
        fclose(of); free(rew);
    }
    int outpipe[2] = {-1,-1};
    if (pipe(outpipe) != 0) { log_line("dhake","error","pipe failed"); unlink(bootbf); return -1; }
    pid_t pid = fork();
    if (pid < 0) { close(outpipe[0]); close(outpipe[1]); log_line("dhake","error","fork failed"); unlink(bootbf); return -1; }
    if (pid == 0) {
        /* child */
        close(outpipe[0]);
        dup2(outpipe[1], 1);
        dup2(outpipe[1], 2);
        close(outpipe[1]);
        char *const av[] = { (char*)"dhake.com", (char*)"-f", (char*)bootbf, (char*)"rootfs", NULL };
        execv(g_dhake, av);
        /* if execv fails, write and exit nonzero */
        const char *m = "fx-init: exec dhake failed\n";
        write(2, m, strlen(m));
        _exit(127);
    }
    close(outpipe[1]);
    /* read dhake output, emit each line to the log DB */
    FILE *r = fdopen(outpipe[0], "r");
    if (r) {
        char line[1024];
        while (fgets(line, sizeof line, r)) {
            size_t L = strlen(line);
            if (L && line[L-1] == '\n') line[L-1] = '\0';
            log_line("dhake", "info", line);
        }
        fclose(r);
    } else close(outpipe[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    unlink(bootbf);   /* clean up the rewritten boot buildfile */
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return rc;
}

/* ─── readiness + supervision ──────────────────────────────────────────────── */

/* is the on= condition satisfied for starting `sv`?  (readiness graph) */
static int on_ready(Svc *sv) {
    switch (sv->on_kind) {
        case FX_ON_ALL: return 1;
        case FX_ON_UP: { Svc *d = svc_find(sv->on_arg); return d && d->ready; }
        case FX_ON_TIME: { uint32_t ms = (uint32_t)strtoul(sv->on_arg, NULL, 10);
            return (uint32_t)((time(NULL) - g_boot_start) * 1000) >= ms; }
        case FX_ON_NET: { /* probe net for any non-lo iface up */
            dl_iter *it = dl_iter_open(g_rt, "net", NULL, 0);
            int hit = 0;
            if (it) { uint32_t r[6]; while (dl_iter_next(it, r) == 1) {
                const char *iface = dl_intern_str_of(g_rt, r[0]);
                const char *st = dl_intern_str_of(g_rt, r[3]);
                if (iface && strcmp(iface, "lo") && st && !strcmp(st, "up")) { hit = 1; break; }
            } dl_iter_close(it); }
            return hit;
        }
        case FX_ON_SOCK_TCP: case FX_ON_SOCK_UNIX: {
            /* readiness via successful connect — gated at start time */
            return 1;  /* handled in start loop retries; treat as startable */
        }
    }
    return 1;
}

/* run the configured readiness probe (Tcp/Unix/File).  1 = ready. */
static int probe_ready(Svc *sv) {
    if (sv->probe_kind == FX_PROBE_NONE) return 1;
    if (sv->probe_kind == FX_PROBE_FILE) return access(sv->probe_arg, F_OK) == 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    if (sv->probe_kind == FX_PROBE_UNIX) {
        strncpy(a.sun_path, sv->probe_arg, sizeof a.sun_path - 1);
    } else { /* TCP: probe a unix-ish path is wrong; use AF_INET for tcp */
        close(fd); fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return 0;
        struct sockaddr_in ai; memset(&ai, 0, sizeof ai);
        ai.sin_family = AF_INET; ai.sin_port = htons((uint16_t)strtoul(sv->probe_arg, NULL, 10));
        ai.sin_addr.s_addr = htonl(0x7f000001);  /* 127.0.0.1 */
        int ok = (connect(fd, (struct sockaddr *)&ai, sizeof ai) == 0);
        close(fd); return ok;
    }
    int ok = (connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
    close(fd);
    return ok;
}

/* fork+setsid+execv a service; stdout/stderr piped to init for log capture.
 * On exec failure the child exits and waitpid reports it (START-FAILURE). */
static void start_service(Svc *sv) {
    int outpipe[2] = {-1,-1};
    if (pipe(outpipe) != 0) { log_line(sv->name, "error", "pipe failed"); return; }
    pid_t pid = fork();
    if (pid < 0) { close(outpipe[0]); close(outpipe[1]); log_line(sv->name,"error","fork failed"); return; }
    if (pid == 0) {
        close(outpipe[0]);
        dup2(outpipe[1], 1);
        dup2(outpipe[1], 2);
        close(outpipe[1]);
        setsid();
        /* env: FX_SVC_NAME, FX_RUN_DIR, PATH=/bin, + svc_env */
        setenv("FX_SVC_NAME", sv->name, 1);
        setenv("FX_RUN_DIR", g_run, 1);
        setenv("PATH", "/bin", 1);
        for (int i = 0; i < sv->nenv; i++) setenv(sv->env_k[i], sv->env_v[i], 1);
        execv(sv->argv[0], sv->argv);
        const char *m = "fx-init: exec failed\n";
        write(2, m, strlen(m));
        _exit(127);
    }
    close(outpipe[1]);
    sv->pid = pid;
    sv->state = ST_STARTED;
    sv->started_at = time(NULL);
    sv->out_fd = outpipe[0];
    fcntl(sv->out_fd, F_SETFL, fcntl(sv->out_fd, F_GETFL) | O_NONBLOCK);
    rt_txn_begin();
    rt_set_service(sv);
    rt_txn_commit();
    char m[256]; snprintf(m, sizeof m, "started (pid %d)", (int)pid);
    log_line(sv->name, "info", m);
}

static void stop_service(Svc *sv) {
    if (sv->pid > 0) {
        kill(sv->pid, SIGTERM);
        log_line(sv->name, "info", "stopping (SIGTERM)");
    }
}

/* drain a service's stdout pipe into the log DB, line-buffered */
static void drain_pipe(Svc *sv) {
    if (sv->out_fd < 0) return;
    char buf[4096];
    ssize_t n = read(sv->out_fd, buf, sizeof buf - 1);
    if (n <= 0) { if (n == 0 || errno != EAGAIN) { close(sv->out_fd); sv->out_fd = -1; } return; }
    buf[n] = '\0';
    /* emit each line (best-effort; partial lines kept simple here) */
    char *save = NULL, *tok = strtok_r(buf, "\n", &save);
    while (tok) { log_line(sv->name, "info", tok); tok = strtok_r(NULL, "\n", &save); }
}

/* evaluate the START-ONLY boot-ok rule (once, at grace expiry).
 *
 * Boot reaches 'ok' only when the FULL grace window has elapsed with every
 * service STARTED and none having exited during the window.  A service that
 * exits during the grace window is a start-failure: reap_children() pins boot
 * failed (and sets g_boot_decided) the moment it reaps such an exit, so by the
 * time we declare ok here we know no service died during boot.  This closes
 * the boot-ok semantics gap where fx-init marked a crasher STARTED on
 * fork+exec success and boot 'ok' the instant all services reached STARTED,
 * even though the crasher kept dying within the grace window.  After boot-ok
 * is decided, health regressions restart in place without touching
 * boot_status.  Distinguishes the two intended failure modes cleanly:
 *   - config-bad-exit (crasher exits during grace) -> failed via reap pin;
 *   - config-bad-hang (gate never ready, service never starts) -> failed via
 *     the grace-timeout branch below. */
static void evaluate_boot_ok(void) {
    if (g_boot_decided) return;
    int all_started = 1, any_failed = 0;
    for (int i = 0; i < g_nsvc; i++) {
        if (g_svc[i].state != ST_STARTED && g_svc[i].state != ST_STOPPED) all_started = 0;
        if (g_svc[i].state == ST_FAILED) any_failed = 1;
    }
    int grace_expired = (time(NULL) >= g_boot_deadline);
    /* ok requires the FULL grace window to elapse: declaring ok the instant
     * all services are STARTED would race a service that crashes a few hundred
     * ms later still inside the grace window.  Waiting until grace-end lets
     * reap_children() pin any in-window exit as failed before we can say ok. */
    if (grace_expired && all_started && !any_failed && g_nsvc > 0) {
        rt_txn_begin();
        rt_set_boot(g_current_version, "ok");
        rt_txn_commit();
        bootlog_append(g_current_version, "ok", now_s());
        log_line("fx-init", "info", "boot ok");
        g_boot_decided = 1; g_boot_failed = 0;
    } else if (grace_expired || any_failed) {
        rt_txn_begin();
        rt_set_boot(g_current_version, "failed");
        rt_txn_commit();
        bootlog_append(g_current_version, "failed", now_s());
        log_line("fx-init", "error", "boot failed");
        g_boot_decided = 1; g_boot_failed = 1;
    }
}

/* ─── SIGCHLD + child reaping ───────────────────────────────────────────────── */

static void sigchld_handler(int sig) {
    (void)sig;
    if (g_sigpipe[1] >= 0) { char b = 'C'; write(g_sigpipe[1], &b, 1); }
}
static void sigterm_handler(int sig) { (void)sig; g_shutdown = 1;
    if (g_sigpipe[1] >= 0) { char b = 'T'; write(g_sigpipe[1], &b, 1); }
}

/* single waitpid(-1, WNOHANG) drain; never blocks */
static void reap_children(void) {
    int status;
    pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        Svc *sv = NULL;
        for (int i = 0; i < g_nsvc; i++) if (g_svc[i].pid == pid) { sv = &g_svc[i]; break; }
        if (!sv) continue;  /* unknown child (e.g. dhake handled separately) */
        int exited_ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        /* fxctl stop sets sv->state = ST_STOPPED before killing the child; a
         * service reaped in that state was explicitly stopped (not a crash) and
         * must NOT count as a boot start-failure.  Capture before we clear the
         * pid / mutate state below. */
        int was_explicit_stop = (sv->state == ST_STOPPED);
        sv->pid = 0;
        if (sv->out_fd >= 0) { close(sv->out_fd); sv->out_fd = -1; }
        if (sv->err_fd >= 0) { close(sv->err_fd); sv->err_fd = -1; }
        char m[256];
        int restart = 0;
        if (sv->restart == FX_RESTART_ALWAYS) restart = 1;
        else if (sv->restart == FX_RESTART_ON_FAILURE) restart = !exited_ok;
        if (was_explicit_stop) restart = 0;  /* explicitly stopped */
        if (restart) {
            sv->restarts++;
            uint32_t bo = sv->cur_backoff ? sv->cur_backoff : sv->backoff_ms;
            if (bo == 0) bo = 1000;
            if (bo > 30000) bo = 30000;
            sv->next_start = time(NULL) + bo;
            sv->cur_backoff = bo * 2;
            if (sv->cur_backoff > 30000) sv->cur_backoff = 30000;
            sv->state = ST_BACKOFF;
            snprintf(m, sizeof m, "exited (%s); restart #%d in %ums",
                     exited_ok ? "ok" : "fail", sv->restarts, bo);
            log_line(sv->name, exited_ok ? "info" : "error", m);
        } else {
            sv->state = exited_ok ? ST_STOPPED : ST_FAILED;
            snprintf(m, sizeof m, "exited (%s); not restarting", exited_ok ? "ok" : "fail");
            log_line(sv->name, exited_ok ? "info" : "error", m);
        }
        rt_txn_begin();
        rt_set_service(sv);
        if (sv->state == ST_STARTED || sv->state == ST_BACKOFF) {
            /* readiness: probe or started-if-no-probe */
            if (sv->probe_kind == FX_PROBE_NONE) rt_set_ready(sv, 1);
            else if (probe_ready(sv)) rt_set_ready(sv, 1);
        }
        rt_txn_commit();

        /* BOOT-OK SEMANTICS: a service that exits during the boot grace
         * window (before boot-ok is decided) is a start-failure.  Pin boot
         * failed + append .bootlog + set g_boot_decided so evaluate_boot_ok()
         * can never flip it to ok — matching the boot-status pin already
         * applied on dhake-materialization failure.  This is what makes
         * config-bad-exit (crasher, restart=always) fail the boot instead of
         * reaching ok the instant the crasher is STARTED.  The service keeps
         * restarting per its restart policy (system stays running, fxctl-
         * inspectable; rollback happens on the NEXT boot).  An explicitly
         * stopped service is excluded.  After boot-ok is decided, exits
         * restart in place and never touch boot_status. */
        if (!g_boot_decided && !was_explicit_stop) {
            rt_txn_begin();
            rt_set_boot(g_current_version, "failed");
            rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            log_line("fx-init", "error", "boot failed: service exited during grace window");
            g_boot_decided = 1;
            g_boot_failed = 1;
        }
    }
}

/* ─── control socket server ────────────────────────────────────────────────── */

/* schema: which columns are interned strings (resolve via dl_intern_str_of) */
struct RelSchema { const char *name; uint8_t arity; uint8_t strcol[8]; };
static const struct RelSchema RELS[] = {
    {"generation_current",1,{0}},
    {"boot_status",2,{1}},
    {"service_runtime",4,{1,0,1,0}},
    {"ready",1,{1}},
    {"control",3,{0,1,1}},
    {"effect",3,{0,1,1}},
    {"process",6,{0,0,0,1,1,0}},
    {"fs",5,{1,1,0,0,0}},
    {"file",6,{1,0,0,0,0,0}},
    {"device",5,{1,0,0,1,0}},
    {"kernel",7,{1,1,1,0,0,0,0}},
    {"net",6,{1,1,1,1,0,0}},
    {"env",2,{1,1}},
};
static const struct RelSchema *find_schema(const char *name) {
    for (size_t i = 0; i < sizeof RELS/sizeof RELS[0]; i++)
        if (!strcmp(RELS[i].name, name)) return &RELS[i];
    return NULL;
}

/* stream one tuple as a tab-separated line into a FILE */
static void emit_tuple(FILE *o, struct dl_db *db, const struct RelSchema *rs, const uint32_t *c) {
    for (int i = 0; i < rs->arity; i++) {
        if (i) fputc('\t', o);
        if (rs->strcol[i]) { const char *s = dl_intern_str_of(db, c[i]); fputs(s ? s : "?", o); }
        else fprintf(o, "%u", c[i]);
    }
    fputc('\n', o);
}

typedef struct { FILE *o; struct dl_db *db; const struct RelSchema *rs; } QCtx;
static int query_cb(const uint32_t *c, uint8_t ar, void *u) {
    (void)ar; QCtx *q = (QCtx *)u;
    emit_tuple(q->o, q->db, q->rs, c);
    return 0;
}

/* respond helpers */
static void resp_ok(FILE *o) { fputs("OK\n", o); fflush(o); }
static void resp_err(FILE *o, const char *msg) { fprintf(o, "ERR %s\n", msg); fflush(o); }

/* log emit callbacks for grep/search streaming to the control socket */
typedef struct { FILE *o; struct dl_db *db; } grep_emit_ctx;
static int grep_log_cb(uint32_t ts, const char *svc, const char *lvl, const char *msg, void *u) {
    (void)((grep_emit_ctx *)u)->db;
    grep_emit_ctx *g = (grep_emit_ctx *)u;
    fprintf(g->o, "%u\t%s\t%s\t%s\n", ts, svc, lvl, msg);
    return 0;
}
static int search_log_cb(uint32_t ts, const char *svc, const char *lvl, const char *msg, void *u) {
    return grep_log_cb(ts, svc, lvl, msg, u);
}

/* dispatch one request line; writes response lines + OK/ERR to `o` */
static void handle_request(FILE *o, char *line) {
    /* tokenize the line (spaces) */
    char *save = NULL;
    char *cmd = strtok_r(line, " \t", &save);
    if (!cmd) { resp_err(o, "empty"); return; }

    if (!strcmp(cmd, "status")) {
        /* boot_status, generation_current, service_runtime summary */
        fprintf(o, "boot_status:\n");
        { dl_iter *it = dl_iter_open(g_rt, "boot_status", NULL, 0);
          if (it) { uint32_t r[2]; while (dl_iter_next(it, r) == 1)
              fprintf(o, "  %u\t%s\n", r[0], dl_intern_str_of(g_rt, r[1])); dl_iter_close(it); } }
        fprintf(o, "generation_current:\n");
        { dl_iter *it = dl_iter_open(g_rt, "generation_current", NULL, 0);
          if (it) { uint32_t r[1]; while (dl_iter_next(it, r) == 1)
              fprintf(o, "  %u\n", r[0]); dl_iter_close(it); } }
        fprintf(o, "service_runtime:\n");
        { const struct RelSchema *rs = find_schema("service_runtime");
          QCtx q = { o, g_rt, rs };
          dl_iter *it = dl_iter_open(g_rt, "service_runtime", NULL, 0);
          if (it) { uint32_t r[4]; while (dl_iter_next(it, r) == 1) query_cb(r, 4, &q); dl_iter_close(it); } }
        resp_ok(o); return;
    }

    if (!strcmp(cmd, "q")) {
        char *rel = strtok_r(NULL, " \t", &save);
        if (!rel) { resp_err(o, "q <rel> [vals]"); return; }
        const struct RelSchema *rs = find_schema(rel);
        if (!rs) { resp_err(o, "unknown relation"); return; }
        /* remaining tokens = bound prefix values */
        uint32_t lead[8]; int k = 0;
        char *tok;
        while (k < 8 && (tok = strtok_r(NULL, " \t", &save))) {
            if (rs->strcol[k]) lead[k] = isym(g_rt, tok);
            else lead[k] = (uint32_t)strtoul(tok, NULL, 10);
            k++;
        }
        QCtx q = { o, g_rt, rs };
        long n;
        if (k > 0) n = dl_query_bound(g_rt, rel, lead, (uint8_t)k, query_cb, &q);
        else n = dl_query(g_rt, rel, query_cb, &q);
        if (n < 0) { resp_err(o, "query failed"); return; }
        resp_ok(o); return;
    }

    if (!strcmp(cmd, "start") || !strcmp(cmd, "stop") || !strcmp(cmd, "restart")) {
        char *name = strtok_r(NULL, " \t", &save);
        if (!name) { resp_err(o, "start|stop|restart <svc>"); return; }
        uint32_t txn = g_txn_id++;
        rt_txn_begin();
        rt_control(txn, cmd, name);
        rt_txn_commit();
        Svc *sv = svc_find(name);
        if (!sv) { resp_err(o, "unknown service"); return; }
        if (!strcmp(cmd, "start")) { if (sv->pid <= 0) start_service(sv); }
        else if (!strcmp(cmd, "stop")) { sv->state = ST_STOPPED; stop_service(sv); }
        else { /* restart */ sv->state = ST_STOPPED; stop_service(sv); sv->next_start = time(NULL); }
        rt_txn_begin(); rt_effect(txn, "applied", name); rt_txn_commit();
        resp_ok(o); return;
    }

    if (!strcmp(cmd, "probe")) {
        char err[256];
        if (fx_probe_refresh(g_rt, g_probe_root, err, sizeof err) != 0) { resp_err(o, err); return; }
        resp_ok(o); return;
    }

    if (!strcmp(cmd, "shutdown")) {
        uint32_t txn = g_txn_id++;
        rt_txn_begin(); rt_control(txn, "shutdown", ""); rt_txn_commit();
        g_shutdown = 1;
        if (g_sigpipe[1] >= 0) { char b = 'T'; write(g_sigpipe[1], &b, 1); }
        resp_ok(o); return;
    }

    if (!strcmp(cmd, "activate") || !strcmp(cmd, "rollback")) {
        char *arg = strtok_r(NULL, " \t", &save);
        if (!arg) { resp_err(o, "activate <path> | rollback <v>"); return; }
        uint32_t txn = g_txn_id++;
        rt_txn_begin(); rt_control(txn, cmd, arg); rt_txn_commit();
        if (!strcmp(cmd, "activate")) {
            char av[1100]; snprintf(av, sizeof av, "%s --store %s --config %s", g_fxstore, g_store, arg);
            int rc = system(av);
            if (rc != 0) { rt_txn_begin(); rt_effect(txn, "activate", "failed"); rt_txn_commit(); resp_err(o, "activate failed"); return; }
            /* re-read CURRENT + facts */
            char e2[1024]; FxStore *s = fx_store_open(g_store, e2, sizeof e2);
            if (!s) { resp_err(o, "store open after activate"); return; }
            fx_store_current_version(s, &g_current_version, e2, sizeof e2); fx_store_close(s);
            read_store_facts(g_current_version);
            rt_txn_begin(); rt_set_generation_current(g_current_version); rt_txn_commit();
            fprintf(o, "activated version %u\n", g_current_version);
            rt_txn_begin(); rt_effect(txn, "version", ""); rt_txn_commit();
            resp_ok(o); return;
        } else { /* rollback */
            uint32_t v = (uint32_t)strtoul(arg, NULL, 10);
            char e2[1024]; FxStore *s = fx_store_open(g_store, e2, sizeof e2);
            if (!s) { resp_err(o, "store open"); return; }
            if (fx_store_rollback(s, v, 0, e2, sizeof e2) != 0) { fx_store_close(s); resp_err(o, e2); return; }
            fx_store_current_version(s, &g_current_version, e2, sizeof e2); fx_store_close(s);
            read_store_facts(g_current_version);
            rt_txn_begin(); rt_set_generation_current(g_current_version); rt_txn_commit();
            fprintf(o, "rolled back to version %u (current %u)\n", v, g_current_version);
            resp_ok(o); return;
        }
    }

    if (!strcmp(cmd, "grep") || !strcmp(cmd, "search")) {
        char *rest = strtok_r(NULL, "", &save);  /* rest of line */
        if (!rest) { resp_err(o, "grep <regex> | search <terms>"); return; }
        /* trim leading spaces */
        while (*rest == ' ' || *rest == '\t') rest++;
        if (!strcmp(cmd, "grep")) {
            grep_emit_ctx gc = { o, g_log };
            long n = fx_log_grep(g_log, rest, grep_log_cb, &gc);
            if (n < 0) { resp_err(o, "grep failed"); return; }
        } else {
            /* tokenize terms */
            char *ts = rest; char *tsave=NULL, *t;
            char *terms[32]; int nt = 0;
            while (nt < 32 && (t = strtok_r(ts, " \t", &tsave))) { terms[nt++] = t; ts = NULL; }
            grep_emit_ctx gc = { o, g_log };
            long n = fx_log_search(g_log, (const char *const *)terms, nt, search_log_cb, &gc);
            if (n < 0) { resp_err(o, "search failed"); return; }
        }
        resp_ok(o); return;
    }

    resp_err(o, "unknown command");
}

static int setup_ctrl(void) {
    char sp[1100]; snprintf(sp, sizeof sp, "%s/control.sock", g_run);
    unlink(sp);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    size_t pl = strlen(sp); if (pl >= sizeof a.sun_path) pl = sizeof a.sun_path - 1;
    memcpy(a.sun_path, sp, pl); a.sun_path[pl] = '\0';
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    if (listen(fd, 8) < 0) { close(fd); return -1; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    return fd;
}

/* handle one accepted control connection: read a line, dispatch, close */
static void handle_conn(int cfd) {
    FILE *o = fdopen(cfd, "w");
    if (!o) { close(cfd); return; }
    FILE *r = fdopen(dup(cfd), "r");
    if (!r) { fclose(o); return; }
    char line[REQ_MAX + 1];
    if (!fgets(line, sizeof line, r)) { fclose(r); fclose(o); return; }
    size_t L = strlen(line);
    if (L && line[L-1] == '\n') line[L-1] = '\0';
    handle_request(o, line);
    fclose(r); fclose(o);
}

/* ─── shutdown ─────────────────────────────────────────────────────────────── */

static void do_shutdown(void) {
    log_line("fx-init", "info", "shutdown");
    /* stop services in reverse start order */
    for (int i = g_nsvc - 1; i >= 0; i--) {
        if (g_svc[i].pid > 0) { kill(g_svc[i].pid, SIGTERM); g_svc[i].state = ST_STOPPED; }
    }
    /* 5s grace then SIGKILL */
    for (int round = 0; round < 50; round++) {
        int alive = 0;
        for (int i = 0; i < g_nsvc; i++) if (g_svc[i].pid > 0) alive = 1;
        if (!alive) break;
        int status; pid_t pid;
        while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
            for (int i = 0; i < g_nsvc; i++) if (g_svc[i].pid == pid) {
                g_svc[i].pid = 0; if (g_svc[i].out_fd>=0){close(g_svc[i].out_fd);g_svc[i].out_fd=-1;} break; }
        }
        if (alive) { struct timespec ts = {0,100*1000*1000}; nanosleep(&ts, NULL); }
    }
    for (int i = 0; i < g_nsvc; i++) if (g_svc[i].pid > 0) { kill(g_svc[i].pid, SIGKILL); }
    /* drain remaining children */
    int status; while (waitpid(-1, &status, WNOHANG) > 0) {}
    bootlog_append(g_current_version, "shutdown", now_s());
    char sp[1100]; snprintf(sp, sizeof sp, "%s/control.sock", g_run); unlink(sp);
    if (g_ctrl_fd >= 0) close(g_ctrl_fd);
    if (g_rt) dl_close(g_rt);
    if (g_log) fx_log_close(g_log);
}

/* ─── main loop ─────────────────────────────────────────────────────────────── */

/* compute the poll timeout (ms) to the next scheduled event */
static int next_timeout(void) {
    time_t now = time(NULL);
    int ms = 1000;  /* default wake-up */
    /* boot grace deadline */
    if (!g_boot_decided && g_boot_deadline > now) {
        long d = (long)(g_boot_deadline - now) * 1000; if (d < ms) ms = (int)d;
    }
    /* probe interval */
    if (g_next_probe > now) { long d = (long)(g_next_probe - now) * 1000; if (d < ms) ms = (int)d; }
    /* backoff restarts */
    for (int i = 0; i < g_nsvc; i++) {
        if (g_svc[i].state == ST_BACKOFF && g_svc[i].next_start > now) {
            long d = (long)(g_svc[i].next_start - now) * 1000; if (d < ms) ms = (int)d;
        }
    }
    if (ms < 10) ms = 10;
    return ms;
}

static void main_loop(void) {
    while (!g_shutdown) {
        struct pollfd pf[2 + 64];
        int nfd = 0;
        pf[nfd].fd = g_sigpipe[0]; pf[nfd].events = POLLIN; nfd++;
        if (g_ctrl_fd >= 0) { pf[nfd].fd = g_ctrl_fd; pf[nfd].events = POLLIN; nfd++; }
        for (int i = 0; i < g_nsvc && nfd < (int)(sizeof pf/sizeof pf[0]); i++) {
            if (g_svc[i].out_fd >= 0) { pf[nfd].fd = g_svc[i].out_fd; pf[nfd].events = POLLIN; nfd++; }
        }
        int rv = poll(pf, (nfds_t)nfd, next_timeout());
        if (rv < 0) { if (errno == EINTR) continue; break; }

        /* drain the self-pipe */
        for (int i = 0; i < nfd; i++) {
            if (pf[i].fd == g_sigpipe[0] && (pf[i].revents & POLLIN)) {
                char buf[16]; while (read(g_sigpipe[0], buf, sizeof buf) > 0) {}
                reap_children();
            }
        }
        /* control socket accept */
        if (g_ctrl_fd >= 0) {
            for (int i = 0; i < nfd; i++) {
                if (pf[i].fd == g_ctrl_fd && (pf[i].revents & POLLIN)) {
                    int cfd = accept(g_ctrl_fd, NULL, NULL);
                    if (cfd >= 0) { handle_conn(cfd); }
                }
            }
        }
        /* service output pipes */
        for (int i = 0; i < nfd; i++) {
            for (int j = 0; j < g_nsvc; j++) {
                if (pf[i].fd == g_svc[j].out_fd && (pf[i].revents & (POLLIN|POLLHUP))) {
                    drain_pipe(&g_svc[j]);
                }
            }
        }

        time_t now = time(NULL);

        /* start eligible services (on= readiness graph) */
        rt_txn_begin();
        for (int i = 0; i < g_nsvc; i++) {
            Svc *sv = &g_svc[i];
            if (sv->state == ST_PENDING && on_ready(sv)) {
                rt_set_service(sv);  /* mark starting */
            }
        }
        rt_txn_commit();
        for (int i = 0; i < g_nsvc; i++) {
            Svc *sv = &g_svc[i];
            /* start only when the on= readiness condition is actually met — a
             * service gated on `on=up:X` (or a socket/time/net condition) must
             * NOT be launched until X is ready, even though it is ST_PENDING. */
            if (sv->state == ST_PENDING && on_ready(sv)) { start_service(sv); }
            else if (sv->state == ST_BACKOFF && now >= sv->next_start && on_ready(sv)) {
                sv->state = ST_PENDING; start_service(sv);
            }
        }

        /* re-evaluate readiness for started services (probe or started) */
        for (int i = 0; i < g_nsvc; i++) {
            Svc *sv = &g_svc[i];
            if (sv->state == ST_STARTED && !sv->ready) {
                if (sv->probe_kind == FX_PROBE_NONE) {
                    rt_txn_begin(); rt_set_ready(sv, 1); rt_txn_commit();
                } else if (probe_ready(sv)) {
                    rt_txn_begin(); rt_set_ready(sv, 1); rt_txn_commit();
                }
            }
        }

        /* boot-ok evaluation */
        evaluate_boot_ok();

        /* probe refresh */
        if (now >= g_next_probe) {
            char err[256];
            fx_probe_refresh(g_rt, g_probe_root, err, sizeof err);
            g_next_probe = now + g_probe_s;
        }

        /* log rotation */
        if (g_log) fx_log_rotate(g_log, g_log_cap);
    }
}

/* ─── main ─────────────────────────────────────────────────────────────────── */

static void usage(FILE *o) {
    fprintf(o,
        "fx-init — fixpoint-linux PID1/supervisor\n"
        "usage: fx-init [--store DIR] [--run-dir DIR] [--probe-interval-s N]\n"
        "                [--log-cap N] [--grace-ms N] [--probe-fixture-root DIR]\n"
        "  --store DIR              store root (default %s)\n"
        "  --run-dir DIR            runtime dir (default %s)\n"
        "  --probe-interval-s N     probe refresh seconds (default %d)\n"
        "  --log-cap N              log tuple cap before rotation (default %llu)\n"
        "  --grace-ms N            boot grace timeout ms (default %u)\n"
        "  --probe-fixture-root DIR test-only /proc,/sys,/etc root\n",
        DEFAULT_STORE, DEFAULT_RUN, DEFAULT_PROBE_S,
        (unsigned long long)DEFAULT_LOG_CAP, DEFAULT_GRACE_MS);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--store")) { if (++i>=argc) { usage(stderr); return 2; } g_store = argv[i]; }
        else if (!strcmp(a, "--run-dir")) { if (++i>=argc) { usage(stderr); return 2; } snprintf(g_run,sizeof g_run,"%s",argv[i]); }
        else if (!strcmp(a, "--probe-interval-s")) { if (++i>=argc) { usage(stderr); return 2; } g_probe_s = atoi(argv[i]); }
        else if (!strcmp(a, "--log-cap")) { if (++i>=argc) { usage(stderr); return 2; } g_log_cap = (uint64_t)strtoul(argv[i],NULL,10); }
        else if (!strcmp(a, "--grace-ms")) { if (++i>=argc) { usage(stderr); return 2; } g_grace_ms = (uint32_t)strtoul(argv[i],NULL,10); }
        else if (!strcmp(a, "--probe-fixture-root")) { if (++i>=argc) { usage(stderr); return 2; } g_probe_root = argv[i]; }
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(stdout); return 0; }
        else { fprintf(stderr, "fx-init: unknown arg '%s'\n", a); usage(stderr); return 2; }
    }

    /* GUARD: PID1 or FX_INIT_FORCE */
    if (getpid() != 1 && !getenv("FX_INIT_FORCE")) {
        fprintf(stderr, "fx-init: refusing to run (not PID1; set FX_INIT_FORCE=1 to override)\n");
        return 1;
    }

    /* signal handlers + self-pipe */
    if (pipe(g_sigpipe) != 0) { fprintf(stderr, "fx-init: pipe: %s\n", strerror(errno)); return 1; }
    fcntl(g_sigpipe[0], F_SETFL, fcntl(g_sigpipe[0], F_GETFL) | O_NONBLOCK);
    fcntl(g_sigpipe[1], F_SETFL, fcntl(g_sigpipe[1], F_GETFL) | O_NONBLOCK);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = sigchld_handler;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP; sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = sigterm_handler; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* runtime + log DBs (held for life) */
    mkdirp(g_run);
    char rtp[1100]; snprintf(rtp, sizeof rtp, "%s/state.db", g_run);
    g_rt = dl_open(rtp);
    if (!g_rt) { fprintf(stderr, "fx-init: dl_open %s: %s\n", rtp, strerror(errno)); return 1; }
    if (declare_runtime(g_rt) != 0) { fprintf(stderr, "fx-init: declare_runtime failed\n"); return 1; }
    char lp[1100]; snprintf(lp, sizeof lp, "%s/log.db", g_run);
    g_log = fx_log_open(lp);
    if (!g_log) fprintf(stderr, "fx-init: warning: log DB open failed (logging disabled)\n");

    /* initial probe */
    char perr[256];
    fx_probe_refresh(g_rt, g_probe_root, perr, sizeof perr);
    g_next_probe = time(NULL) + g_probe_s;

    /* boot decision + read facts */
    g_boot_start = time(NULL);
    uint32_t boot_v = decide_boot_version();
    if (boot_v == 0 || read_store_facts(boot_v) != 0) {
        fprintf(stderr, "fx-init: no generation to boot\n");
        /* still run (control socket up so fxctl can activate) */
        g_boot_version = 0;
        g_boot_deadline = g_boot_start + (g_grace_ms / 1000);
    } else {
        g_boot_version = boot_v;
        /* boot_grace(ms) fact (read in read_store_facts) overrides the default
         * grace; compute the deadline AFTER the override so per-activation
         * bootGraceMs (e.g. config-bad-hang's 2000ms) is honored. */
        g_boot_deadline = g_boot_start + (g_grace_ms / 1000);
        bootlog_append(g_current_version, "in-progress", now_s());
        /* materialize rootfs via dhake */
        log_line("fx-init", "info", "materializing rootfs via dhake");
        int drc = run_dhake();
        int dhake_failed = (drc != 0);
        if (dhake_failed) {
            char m[256]; snprintf(m, sizeof m, "dhake exited %d", drc);
            log_line("fx-init", "error", m);
            rt_txn_begin(); rt_set_boot(g_current_version, "failed"); rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            /* A failed rootfs materialization means the boot can NEVER reach ok:
             * /etc + /bin were not materialized, so the system is not usable.
             * Pin the decision so evaluate_boot_ok() (START-ONLY grace rule)
             * cannot later flip boot_status to ok — without this the
             * unconditional in-progress set below would mask the failure, and
             * the grace rule could mark the boot ok even though dhake failed
             * (the observed bug: .bootlog showed in-progress -> failed -> ok). */
            g_boot_decided = 1;
            g_boot_failed = 1;
        }
        rt_txn_begin();
        rt_set_generation_current(g_current_version);
        if (!dhake_failed) rt_set_boot(g_current_version, "in-progress");
        for (int i = 0; i < g_nsvc; i++) rt_set_service(&g_svc[i]);
        rt_txn_commit();
    }

    /* control socket */
    g_ctrl_fd = setup_ctrl();
    if (g_ctrl_fd < 0) fprintf(stderr, "fx-init: warning: control socket failed\n");

    log_line("fx-init", "info", "entered main loop");
    main_loop();
    do_shutdown();
    return 0;
}
