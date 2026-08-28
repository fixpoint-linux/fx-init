/* log_probe_live.c — ONE-PROCESS differential for UNIT 3: src/fx_log.c and
 * src/fx_probe.c (C) vs their Zig ports (zig/src/log.zig, zig/src/probe.zig,
 * linked as the log_port/probe_port objects exposing zig_log_* / zig_probe_*).
 *
 * Both sides run in the SAME process against the SAME C engine (fxengine
 * static lib), so every environmental input — statvfs, uname, environ,
 * sysconf(_SC_PAGESIZE), the fixture tree — is identical by construction and
 * the dumps must be BYTE-IDENTICAL at string level (sym ids are resolved
 * through dl_intern_str_of before comparing).
 *
 * Part 1 (log): open two throwaway DBs, run an identical scripted emit /
 * grep / search / rotate sequence on C-fx_log and Zig-log (the script is the
 * tests/log_test.c contract plus extra tokenize/dup-msg/empty-msg coverage),
 * dump the log + __postings__ relations sorted at every checkpoint, and
 * assert byte-identity everywhere.
 *
 * Part 2 (probe): build the probe fixture tree from tests/probe_test.c, run
 * C-fx_probe_refresh and Zig-probe on two DBs with the SAME fixture root,
 * dump all 7 relations sorted, assert byte-identity, and replay the
 * probe_test.c assertions against the Zig DB.
 */
#include "fx_log.h"
#include "fx_probe.h"
#include "dl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>

/* the Zig ports (wrapper objects) */
extern struct dl_db *zig_log_open(const char *path);
extern void zig_log_close(struct dl_db *db);
extern int zig_log_emit(struct dl_db *db, uint32_t ts, const char *svc,
                        const char *level, const char *msg);
extern uint64_t zig_log_count(struct dl_db *db);
extern long zig_log_grep(struct dl_db *db, const char *regex, fx_log_cb cb, void *user);
extern long zig_log_search(struct dl_db *db, const char *const *terms, int nterms,
                           fx_log_cb cb, void *user);
extern int zig_log_rotate(struct dl_db *db, uint64_t cap);
extern int zig_probe_declare(struct dl_db *rt);
extern int zig_probe_refresh(struct dl_db *rt, const char *root, char *err, size_t errcap);

static int checks = 0, fails = 0;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { fails++; printf("FAIL: " __VA_ARGS__); putchar('\n'); } } while (0)

/* ─── byte-identity helpers ──────────────────────────────────────────────── */

typedef struct { char *s; size_t len, cap; } Buf;

static void bput(Buf *b, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0) { va_end(ap2); return; }
    if (b->len + (size_t)need + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 4096;
        while (b->len + (size_t)need + 1 > nc) nc *= 2;
        char *ns = realloc(b->s, nc);
        if (!ns) { fprintf(stderr, "OOM\n"); exit(2); }
        b->s = ns;
        b->cap = nc;
    }
    vsnprintf(b->s + b->len, (size_t)need + 1, fmt, ap2);
    b->len += (size_t)need;
    va_end(ap2);
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

/* Dump one relation at STRING level: one line per tuple
 * "rel\tcol0\tcol1...\n", sym columns resolved via dl_intern_str_of, sorted
 * with qsort.  Returns a malloc'd buffer (never NULL). */
static char *dump_rel(struct dl_db *db, const char *rel, uint8_t arity,
                      uint32_t symmask, size_t *out_len) {
    char **lines = NULL;
    size_t n = 0, cap = 0;
    dl_iter *it = dl_iter_open(db, rel, NULL, 0);
    if (it) {
        uint8_t ar = dl_iter_arity(it);
        uint32_t cols[8];
        while (dl_iter_next(it, cols) == 1) {
            Buf line = {0};
            bput(&line, "%s", rel);
            for (uint8_t i = 0; i < ar && i < 8; i++) {
                if (symmask & (1u << i)) {
                    const char *s = dl_intern_str_of(db, cols[i]);
                    bput(&line, "\t%s", s ? s : "?");
                } else {
                    bput(&line, "\t%u", cols[i]);
                }
            }
            if (n == cap) {
                cap = cap ? cap * 2 : 64;
                lines = realloc(lines, cap * sizeof *lines);
                if (!lines) { fprintf(stderr, "OOM\n"); exit(2); }
            }
            lines[n++] = line.s ? line.s : strdup("");
        }
        dl_iter_close(it);
    }
    if (lines) qsort(lines, n, sizeof *lines, cmp_str);
    Buf out = {0};
    for (size_t i = 0; i < n; i++) {
        bput(&out, "%s\n", lines[i]);
        free(lines[i]);
    }
    free(lines);
    if (!out.s) out.s = strdup("");
    if (out_len) *out_len = out.len;
    return out.s;
}

/* bit i set => column i is an interned sym */
#define LOG_RELS \
    { "log", 4, 0xEu }, { "__postings__", 2, 0x0u }
static const struct { const char *rel; uint8_t arity; uint32_t symmask; } log_rels[] = { LOG_RELS };
static const struct { const char *rel; uint8_t arity; uint32_t symmask; } rt_rels[] = {
    { "process", 6, 0x18u },   /* comm, state */
    { "fs", 5, 0x03u },        /* path, fstype */
    { "file", 6, 0x01u },      /* path */
    { "device", 5, 0x09u },    /* name, type */
    { "kernel", 7, 0x07u },    /* version, release, hostname */
    { "net", 6, 0x0Fu },       /* iface, addr, mac, state */
    { "env", 2, 0x03u },       /* key, value */
};

static void dump_db(const struct { const char *rel; uint8_t arity; uint32_t symmask; } *specs,
                    size_t nspecs, struct dl_db *db, Buf *out) {
    for (size_t i = 0; i < nspecs; i++) {
        size_t len = 0;
        char *d = dump_rel(db, specs[i].rel, specs[i].arity, specs[i].symmask, &len);
        bput(out, "%s", d);
        free(d);
    }
}

static void check_dump_same(const char *what, const Buf *c, const Buf *z) {
    checks++;
    if (c->s && z->s && c->len == z->len && memcmp(c->s, z->s, c->len) == 0) {
        printf("    OK %s (%zu bytes identical)\n", what, c->len);
        return;
    }
    fails++;
    printf("FAIL %s differ (c=%zu bytes, zig=%zu bytes)\n", what,
           c->s ? c->len : 0, z->s ? z->len : 0);
    if (c->s && z->s) {
        size_t i = 0;
        while (i < c->len && i < z->len && c->s[i] == z->s[i]) i++;
        size_t lo = i > 40 ? i - 40 : 0;
        size_t w = i - lo + 40;
        printf("    first diff at byte %zu\n    c  : <<%.*s>>\n    zig: <<%.*s>>\n",
               i, (int)(w < c->len - lo ? w : c->len - lo), c->s + lo,
               (int)(w < z->len - lo ? w : z->len - lo), z->s + lo);
    }
}

/* ─── log collect callback (same shape as tests/log_test.c) ─────────────── */

typedef struct { char buf[65536]; size_t off; long n; } Collect;

static int collect_cb(uint32_t ts, const char *svc, const char *level,
                      const char *msg, void *user) {
    Collect *c = (Collect *)user;
    c->n++;
    int w = snprintf(c->buf + c->off, sizeof c->buf - c->off,
                     "%u\t%s\t%s\t%s\n", ts, svc, level, msg);
    if (w > 0) c->off += (size_t)w;
    return 0;
}

static void check_collect_same(const char *what, long rc, long rz,
                               const Collect *gc, const Collect *gz) {
    CHECK(rc == rz, "%s: rc c=%ld zig=%ld", what, rc, rz);
    CHECK(gc->n == gz->n, "%s: emitted c=%ld zig=%ld", what, gc->n, gz->n);
    CHECK(gc->off == gz->off && memcmp(gc->buf, gz->buf, gc->off) == 0,
          "%s: collected bytes differ (c=%zu zig=%zu)", what, gc->off, gz->off);
    if (rc == rz && rc >= 0)
        printf("    OK %s (rc=%ld, %ld lines byte-identical)\n", what, rc, rc);
}

/* ─── fixture helpers (from tests/probe_test.c) ──────────────────────────── */

static void mkp(const char *path) {
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0755);
            *p = '/';
        }
    }
    mkdir(buf, 0755);
}

static void wf(const char *path, const char *content) {
    char dir[1024];
    snprintf(dir, sizeof dir, "%s", path);
    char *sl = strrchr(dir, '/');
    if (sl) { *sl = '\0'; mkp(dir); }
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path); return; }
    fputs(content, f);
    fclose(f);
}

/* find a process tuple by pid (probe_test.c helper) */
static int find_process(struct dl_db *db, uint32_t pid, uint32_t cols[6]) {
    dl_iter *it = dl_iter_open(db, "process", &pid, 1);
    if (!it) return 0;
    int got = (dl_iter_next(it, cols) == 1) ? 1 : 0;
    dl_iter_close(it);
    return got;
}

static int find_net(struct dl_db *db, const char *iface, uint32_t cols[6]) {
    uint32_t isym = dl_intern_str(db, iface);
    if (!isym) return 0;
    dl_iter *it = dl_iter_open(db, "net", &isym, 1);
    if (!it) return 0;
    int got = (dl_iter_next(it, cols) == 1) ? 1 : 0;
    dl_iter_close(it);
    return got;
}

/* ─── part 1: log ────────────────────────────────────────────────────────── */

static void log_part(void) {
    char dbc[512], dbz[512];
    snprintf(dbc, sizeof dbc, "/tmp/fxlogC-XXXXXX");
    snprintf(dbz, sizeof dbz, "/tmp/fxlogZ-XXXXXX");
    if (!mkdtemp(dbc) || !mkdtemp(dbz)) { fprintf(stderr, "mkdtemp failed\n"); exit(2); }

    struct dl_db *c = fx_log_open(dbc);
    struct dl_db *z = zig_log_open(dbz);
    CHECK(c != NULL, "fx_log_open");
    CHECK(z != NULL, "zig_log_open");
    if (!c || !z) exit(2);

    /* the tests/log_test.c emit script (4 base lines) */
    CHECK(fx_log_emit(c, 100, "svcA", "info", "starting up") == 0, "c emit 1");
    CHECK(zig_log_emit(z, 100, "svcA", "info", "starting up") == 0, "zig emit 1");
    CHECK(fx_log_emit(c, 101, "svcA", "info", "heartbeat ok") == 0, "c emit 2");
    CHECK(zig_log_emit(z, 101, "svcA", "info", "heartbeat ok") == 0, "zig emit 2");
    CHECK(fx_log_emit(c, 102, "svcB", "error", "heartbeat ok") == 0, "c emit 3");
    CHECK(zig_log_emit(z, 102, "svcB", "error", "heartbeat ok") == 0, "zig emit 3");
    CHECK(fx_log_emit(c, 103, "svcA", "info", "shutting down") == 0, "c emit 4");
    CHECK(zig_log_emit(z, 103, "svcA", "info", "shutting down") == 0, "zig emit 4");

    CHECK(fx_log_count(c) == 4, "c count==4");
    CHECK(zig_log_count(z) == 4, "REPLAY log_test: zig count==4 (got %llu)",
          (unsigned long long)zig_log_count(z));

    /* checkpoint 1 dump */
    Buf dc1 = {0}, dz1 = {0};
    dump_db(log_rels, 2, c, &dc1);
    dump_db(log_rels, 2, z, &dz1);
    check_dump_same("log dump after 4 emits (log+__postings__)", &dc1, &dz1);

    /* grep battery (log_test: heartbeat==2, starting==1) */
    Collect gc = {0}, gz = {0};
    long rc = fx_log_grep(c, "heartbeat", collect_cb, &gc);
    long rz = zig_log_grep(z, "heartbeat", collect_cb, &gz);
    check_collect_same("grep heartbeat", rc, rz, &gc, &gz);
    CHECK(rz == 2, "REPLAY log_test: zig grep heartbeat == 2 (got %ld)", rz);

    Collect gc2 = {0}, gz2 = {0};
    rc = fx_log_grep(c, "starting", collect_cb, &gc2);
    rz = zig_log_grep(z, "starting", collect_cb, &gz2);
    check_collect_same("grep starting", rc, rz, &gc2, &gz2);
    CHECK(rz == 1, "REPLAY log_test: zig grep starting == 1 (got %ld)", rz);

    /* search battery (log_test: 2 / 1 / 0) */
    const char *terms1[] = { "heartbeat", "ok" };
    Collect sc1 = {0}, sz1 = {0};
    rc = fx_log_search(c, terms1, 2, collect_cb, &sc1);
    rz = zig_log_search(z, terms1, 2, collect_cb, &sz1);
    check_collect_same("search heartbeat AND ok", rc, rz, &sc1, &sz1);
    CHECK(rz == 2, "REPLAY log_test: zig search heartbeat AND ok == 2 (got %ld)", rz);

    const char *terms2[] = { "shutting" };
    Collect sc2 = {0}, sz2 = {0};
    rc = fx_log_search(c, terms2, 1, collect_cb, &sc2);
    rz = zig_log_search(z, terms2, 1, collect_cb, &sz2);
    check_collect_same("search shutting", rc, rz, &sc2, &sz2);
    CHECK(rz == 1, "REPLAY log_test: zig search shutting == 1 (got %ld)", rz);

    const char *terms3[] = { "starting", "down" };
    Collect sc3 = {0}, sz3 = {0};
    rc = fx_log_search(c, terms3, 2, collect_cb, &sc3);
    rz = zig_log_search(z, terms3, 2, collect_cb, &sz3);
    check_collect_same("search starting AND down", rc, rz, &sc3, &sz3);
    CHECK(rz == 0, "REPLAY log_test: zig search starting AND down == 0 (got %ld)", rz);

    /* error paths: NULL db, bad regex, empty terms — identical rc */
    CHECK(fx_log_grep(NULL, "x", collect_cb, NULL) == -1, "c grep NULL db");
    CHECK(zig_log_grep(NULL, "x", collect_cb, NULL) == -1, "zig grep NULL db");
    CHECK(fx_log_grep(c, "(", collect_cb, &gc) < 0, "c grep bad regex");   /* unbalanced -> errmsg */
    CHECK(zig_log_grep(z, "(", collect_cb, &gz) < 0, "REPLAY: zig grep bad regex");
    CHECK(fx_log_search(c, NULL, 0, collect_cb, &gc) == -1, "c search nterms=0");
    CHECK(zig_log_search(z, NULL, 0, collect_cb, &gz) == -1, "REPLAY: zig search nterms=0");
    CHECK(fx_log_count(NULL) == UINT64_MAX, "c count NULL db");
    CHECK(zig_log_count(NULL) == UINT64_MAX, "REPLAY: zig count NULL db");
    CHECK(fx_log_rotate(NULL, 1) == -1, "c rotate NULL db");
    CHECK(zig_log_rotate(NULL, 1) == -1, "REPLAY: zig rotate NULL db");

    /* rotation: cap=2 -> drop oldest quarter (4/4=1) => 3 remain */
    CHECK(fx_log_rotate(c, 2) == 0, "c rotate cap=2");
    CHECK(zig_log_rotate(z, 2) == 0, "zig rotate cap=2");
    CHECK(fx_log_count(c) == 3, "c count==3 after rotate");
    CHECK(zig_log_count(z) == 3, "REPLAY log_test: zig count==3 after rotate (got %llu)",
          (unsigned long long)zig_log_count(z));

    Buf dc2 = {0}, dz2 = {0};
    dump_db(log_rels, 2, c, &dc2);
    dump_db(log_rels, 2, z, &dz2);
    check_dump_same("log dump after rotate cap=2", &dc2, &dz2);

    /* no-op rotate: cap >= n -> 0, count unchanged */
    CHECK(fx_log_rotate(c, 1000) == 0 && zig_log_rotate(z, 1000) == 0, "noop rotate rc");
    CHECK(fx_log_count(c) == zig_log_count(z), "count after noop rotate");

    fx_log_close(c);
    zig_log_close(z);

    /* reopen — relations persist and are re-declarable */
    c = fx_log_open(dbc);
    z = zig_log_open(dbz);
    CHECK(c != NULL && z != NULL, "reopen after rotate");
    CHECK(fx_log_count(c) == 3 && zig_log_count(z) == 3,
          "REPLAY log_test: reopen count==3 (c=%llu zig=%llu)",
          (unsigned long long)fx_log_count(c), (unsigned long long)zig_log_count(z));

    /* larger batch rotation exercises collect-then-delete (log_test:
     * 100 fresh lines -> 103 total; rotate cap=20 -> drop 25 -> 78;
     * ts 222 survives, ts 200 dropped) */
    for (uint32_t t = 200; t < 300; t++) {
        char msg[32];
        snprintf(msg, sizeof msg, "batch line %u", t);
        CHECK(fx_log_emit(c, t, "batch", "info", msg) == 0, "c emit batch %u", t);
        CHECK(zig_log_emit(z, t, "batch", "info", msg) == 0, "zig emit batch %u", t);
    }
    CHECK(fx_log_count(c) == 103, "c count==103 after batch");
    CHECK(zig_log_count(z) == 103, "REPLAY log_test: zig count==103 (got %llu)",
          (unsigned long long)zig_log_count(z));
    CHECK(fx_log_rotate(c, 20) == 0, "c rotate cap=20");
    CHECK(zig_log_rotate(z, 20) == 0, "zig rotate cap=20");
    CHECK(fx_log_count(c) == 78 && zig_log_count(z) == 78,
          "REPLAY log_test: count==78 after batch rotate (c=%llu zig=%llu)",
          (unsigned long long)fx_log_count(c), (unsigned long long)zig_log_count(z));

    Collect bc = {0}, bz = {0};
    rc = fx_log_grep(c, "batch line 222", collect_cb, &bc);
    rz = zig_log_grep(z, "batch line 222", collect_cb, &bz);
    check_collect_same("grep batch line 222 (survivor)", rc, rz, &bc, &bz);
    CHECK(rz == 1, "REPLAY log_test: zig grep ts 222 == 1 (got %ld)", rz);

    Collect bc2 = {0}, bz2 = {0};
    rc = fx_log_grep(c, "batch line 200", collect_cb, &bc2);
    rz = zig_log_grep(z, "batch line 200", collect_cb, &bz2);
    check_collect_same("grep batch line 200 (dropped)", rc, rz, &bc2, &bz2);
    CHECK(rz == 0, "REPLAY log_test: zig grep ts 200 == 0 (got %ld)", rz);

    /* extra coverage beyond log_test: dup msg across svc, tokenize-heavy,
     * punctuation-only, empty msg, then regex/search battery #2 */
    CHECK(fx_log_emit(c, 106, "svcB", "warn", "starting up") == 0, "c emit dup");
    CHECK(zig_log_emit(z, 106, "svcB", "warn", "starting up") == 0, "zig emit dup");
    CHECK(fx_log_emit(c, 107, "svcC", "info", "Multi Word Tokens: hello_world 42") == 0, "c emit tokens");
    CHECK(zig_log_emit(z, 107, "svcC", "info", "Multi Word Tokens: hello_world 42") == 0, "zig emit tokens");
    CHECK(fx_log_emit(c, 108, "svcD", "info", "!@# $%^ &*()") == 0, "c emit punct");
    CHECK(zig_log_emit(z, 108, "svcD", "info", "!@# $%^ &*()") == 0, "zig emit punct");
    CHECK(fx_log_emit(c, 109, "svcE", "info", "") == 0, "c emit empty");
    CHECK(zig_log_emit(z, 109, "svcE", "info", "") == 0, "zig emit empty");

    Buf dc3 = {0}, dz3 = {0};
    dump_db(log_rels, 2, c, &dc3);
    dump_db(log_rels, 2, z, &dz3);
    check_dump_same("log dump after extra emits (tokenize/postings parity)", &dc3, &dz3);

    /* regex battery #2: classes, alternation, anchored literal, empty regex */
    const char *regexes[] = { "hello_world", "w[oO]rd", "heartbeat|starting",
                              "^starting", "batch line 2[0-9][0-9]", "",
                              "svcE.*never", "42" };
    for (size_t i = 0; i < sizeof regexes / sizeof *regexes; i++) {
        Collect xc = {0}, xz = {0};
        rc = fx_log_grep(c, regexes[i], collect_cb, &xc);
        rz = zig_log_grep(z, regexes[i], collect_cb, &xz);
        check_collect_same("regex battery", rc, rz, &xc, &xz);
    }

    /* search battery #2: multi-word AND, single common term */
    const char *t4[] = { "multi", "word" };
    Collect sc4 = {0}, sz4 = {0};
    rc = fx_log_search(c, t4, 2, collect_cb, &sc4);
    rz = zig_log_search(z, t4, 2, collect_cb, &sz4);
    check_collect_same("search multi AND word", rc, rz, &sc4, &sz4);

    const char *t5[] = { "line" };
    Collect sc5 = {0}, sz5 = {0};
    rc = fx_log_search(c, t5, 1, collect_cb, &sc5);
    rz = zig_log_search(z, t5, 1, collect_cb, &sz5);
    check_collect_same("search line", rc, rz, &sc5, &sz5);

    Buf dc4 = {0}, dz4 = {0};
    dump_db(log_rels, 2, c, &dc4);
    dump_db(log_rels, 2, z, &dz4);
    check_dump_same("final log dump after battery", &dc4, &dz4);

    fx_log_close(c);
    zig_log_close(z);
    free(dc1.s); free(dz1.s); free(dc2.s); free(dz2.s);
    free(dc3.s); free(dz3.s); free(dc4.s); free(dz4.s);
    rmdir(dbc); rmdir(dbz);  /* DBs leave WAL files; ignore failure */
}

/* ─── part 2: probe ──────────────────────────────────────────────────────── */

static void probe_part(void) {
    char root[512];
    snprintf(root, sizeof root, "/tmp/fxprobe-XXXXXX");
    if (!mkdtemp(root)) { fprintf(stderr, "mkdtemp failed\n"); exit(2); }

    /* ── fixture tree, byte-for-byte from tests/probe_test.c ── */
    char p[700];
    snprintf(p, sizeof p, "%s/proc/1/stat", root);
    wf(p, "1 (init) S 0 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 100 4096 100\n");
    snprintf(p, sizeof p, "%s/proc/1/status", root);
    wf(p, "Uid:\t0\t0\t0\t0\n");
    snprintf(p, sizeof p, "%s/proc/100/stat", root);
    wf(p, "100 (worker process) R 1 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 200 8192 256\n");
    snprintf(p, sizeof p, "%s/proc/100/status", root);
    wf(p, "Uid:\t1000\t1000\t1000\t1000\n");

    snprintf(p, sizeof p, "%s/sys/class/net/lo/address", root);
    wf(p, "00:00:00:00:00:00\n");
    snprintf(p, sizeof p, "%s/sys/class/net/lo/operstate", root);
    wf(p, "unknown\n");
    snprintf(p, sizeof p, "%s/sys/class/net/lo/ifindex", root);
    wf(p, "1\n");
    snprintf(p, sizeof p, "%s/sys/class/net/lo/statistics/rx_bytes", root);
    wf(p, "1234\n");
    snprintf(p, sizeof p, "%s/sys/class/net/lo/statistics/tx_bytes", root);
    wf(p, "5678\n");
    snprintf(p, sizeof p, "%s/sys/class/net/eth0/address", root);
    wf(p, "aa:bb:cc:dd:ee:ff\n");
    snprintf(p, sizeof p, "%s/sys/class/net/eth0/operstate", root);
    wf(p, "up\n");
    snprintf(p, sizeof p, "%s/sys/class/net/eth0/ifindex", root);
    wf(p, "2\n");
    snprintf(p, sizeof p, "%s/sys/class/net/eth0/statistics/rx_bytes", root);
    wf(p, "9999\n");
    snprintf(p, sizeof p, "%s/sys/class/net/eth0/statistics/tx_bytes", root);
    wf(p, "1111\n");

    snprintf(p, sizeof p, "%s/proc/loadavg", root);
    wf(p, "0.42 0.20 0.30 1/100 1234\n");
    snprintf(p, sizeof p, "%s/proc/meminfo", root);
    wf(p, "MemTotal: 2048 kB\nMemFree: 1024 kB\n");
    snprintf(p, sizeof p, "%s/proc/uptime", root);
    wf(p, "12345.67 67890.12\n");

    snprintf(p, sizeof p, "%s/etc/hostname", root);
    wf(p, "fixbox\n");

    /* ── two DBs, SAME fixture root ── */
    char dbc[600], dbz[600];
    snprintf(dbc, sizeof dbc, "%s/db-c", root);
    snprintf(dbz, sizeof dbz, "%s/db-z", root);
    mkp(dbc);
    mkp(dbz);
    struct dl_db *c = dl_open(dbc);
    struct dl_db *z = dl_open(dbz);
    CHECK(c != NULL && z != NULL, "probe dl_open x2");
    if (!c || !z) exit(2);

    CHECK(fx_probe_declare(c) == 0, "fx_probe_declare(c)");
    CHECK(zig_probe_declare(z) == 0, "REPLAY: zig_probe_declare(z) == 0");
    CHECK(fx_probe_declare(c) == 0 && zig_probe_declare(z) == 0, "declare idempotent");

    char errc[256], errz[256];
    snprintf(errc, sizeof errc, "OK");
    snprintf(errz, sizeof errz, "OK");
    int rc = fx_probe_refresh(c, root, errc, sizeof errc);
    int rz = zig_probe_refresh(z, root, errz, sizeof errz);
    CHECK(rc == rz && rc == 0, "refresh rc (c=%d '%s' zig=%d '%s')", rc, errc, rz, errz);
    /* on success the C contract leaves err UNTOUCHED — both must still be the sentinel */
    CHECK(strcmp(errc, errz) == 0 && strcmp(errc, "OK") == 0,
          "refresh err untouched on success (c='%s' zig='%s')", errc, errz);

    /* dump all 7 relations, byte-identical */
    Buf dc = {0}, dz = {0};
    dump_db(rt_rels, 7, c, &dc);
    dump_db(rt_rels, 7, z, &dz);
    check_dump_same("probe dump refresh#1 (all 7 relations)", &dc, &dz);

    /* REPLAY probe_test.c assertions against the ZIG DB */
    CHECK(dl_count(z, "process") == 2, "REPLAY probe_test: zig process count == 2 (got %llu)",
          (unsigned long long)dl_count(z, "process"));
    uint32_t cc[8], zz[8];
    CHECK(find_process(z, 1, zz) == 1, "REPLAY: zig find pid 1");
    CHECK(find_process(z, 100, zz) == 1, "REPLAY: zig find pid 100");
    if (find_process(z, 1, zz) == 1) {
        CHECK(zz[0] == 1 && zz[1] == 0 && zz[2] == 0, "REPLAY: pid1 pid/ppid/uid");
        CHECK(!strcmp(dl_intern_str_of(z, zz[3]), "init"), "REPLAY: pid1 comm == init");
        CHECK(!strcmp(dl_intern_str_of(z, zz[4]), "S"), "REPLAY: pid1 state == S");
        CHECK(zz[5] == 400, "REPLAY: pid1 rss_kb == 400 (got %u)", zz[5]);
    }
    if (find_process(z, 100, zz) == 1) {
        CHECK(zz[0] == 100 && zz[1] == 1 && zz[2] == 1000, "REPLAY: pid100 pid/ppid/uid");
        CHECK(!strcmp(dl_intern_str_of(z, zz[3]), "worker process"),
              "REPLAY: pid100 comm (spaces) (got '%s')", dl_intern_str_of(z, zz[3]));
        CHECK(!strcmp(dl_intern_str_of(z, zz[4]), "R"), "REPLAY: pid100 state == R");
        CHECK(zz[5] == 1024, "REPLAY: pid100 rss_kb == 1024 (got %u)", zz[5]);
    }
    CHECK(dl_count(z, "net") == 2, "REPLAY: zig net count == 2");
    CHECK(dl_count(z, "device") == 2, "REPLAY: zig device count == 2");
    CHECK(find_net(z, "lo", zz) == 1 && zz[4] == 1234 && zz[5] == 5678,
          "REPLAY: net lo rx=1234 tx=5678");
    CHECK(find_net(z, "eth0", zz) == 1 && zz[4] == 9999 && zz[5] == 1111,
          "REPLAY: net eth0 rx=9999 tx=1111");
    CHECK(dl_count(z, "kernel") == 1, "REPLAY: zig kernel count == 1");
    dl_iter *it = dl_iter_open(z, "kernel", NULL, 0);
    CHECK(it && dl_iter_next(it, zz) == 1, "REPLAY: zig kernel tuple readable");
    if (it && dl_iter_next(it, zz) == 1) {
        CHECK(zz[5] == 2048, "REPLAY: kernel memtotal == 2048 (got %u)", zz[5]);
        CHECK(zz[6] == 1024, "REPLAY: kernel memfree == 1024 (got %u)", zz[6]);
        CHECK(zz[4] == 42, "REPLAY: kernel load1_x100 == 42 (got %u)", zz[4]);
        CHECK(zz[3] == 12345, "REPLAY: kernel uptime == 12345 (got %u)", zz[3]);
    }
    if (it) dl_iter_close(it);
    CHECK(dl_count(z, "file") == 1, "REPLAY: zig file count == 1");
    CHECK(dl_count(z, "env") > 0, "REPLAY: zig env count > 0");

    /* C-vs-Z symmetric: identical raw cols for the fixture-driven tuples */
    CHECK(find_process(c, 1, cc) == 1 && find_process(z, 1, zz) == 1, "find pid1 both");
    CHECK(memcmp(cc, zz, 6 * 4) == 0, "pid1 cols C==Z");
    CHECK(find_process(c, 100, cc) == 1 && find_process(z, 100, zz) == 1, "find pid100 both");
    CHECK(memcmp(cc, zz, 6 * 4) == 0, "pid100 cols C==Z");
    CHECK(find_net(c, "lo", cc) == 1 && find_net(z, "lo", zz) == 1, "find net lo both");
    CHECK(memcmp(cc, zz, 6 * 4) == 0, "net lo cols C==Z");
    CHECK(find_net(c, "eth0", cc) == 1 && find_net(z, "eth0", zz) == 1, "find net eth0 both");
    CHECK(memcmp(cc, zz, 6 * 4) == 0, "net eth0 cols C==Z");
    it = dl_iter_open(c, "kernel", NULL, 0);
    CHECK(it && dl_iter_next(it, cc) == 1, "c kernel tuple");
    if (it) dl_iter_close(it);
    it = dl_iter_open(z, "kernel", NULL, 0);
    CHECK(it && dl_iter_next(it, zz) == 1, "zig kernel tuple");
    if (it) dl_iter_close(it);
    CHECK(memcmp(cc, zz, 7 * 4) == 0, "kernel cols C==Z");

    /* idempotent re-refresh: counts stable, dumps identical again */
    rc = fx_probe_refresh(c, root, errc, sizeof errc);
    rz = zig_probe_refresh(z, root, errz, sizeof errz);
    CHECK(rc == rz && rc == 0, "refresh#2 rc");
    CHECK(dl_count(c, "process") == 2 && dl_count(z, "process") == 2,
          "REPLAY probe_test: process count still 2 after re-refresh");
    CHECK(dl_count(c, "net") == 2 && dl_count(z, "net") == 2,
          "REPLAY probe_test: net count still 2 after re-refresh");
    dc.len = 0; dz.len = 0;
    dump_db(rt_rels, 7, c, &dc);
    dump_db(rt_rels, 7, z, &dz);
    check_dump_same("probe dump refresh#2 (idempotent)", &dc, &dz);

    free(dc.s);
    free(dz.s);
    dl_close(c);
    dl_close(z);
}

int main(void) {
    printf("== part 1: fx_log differential (C vs Zig, one process) ==\n");
    log_part();
    printf("== part 2: fx_probe differential (C vs Zig, shared fixture root) ==\n");
    probe_part();
    printf("log_probe_live: %d checks, %d failed\n", checks, fails);
    return fails ? 1 : 0;
}
