/* log_probe_live.c — regression driver for the Zig log + probe ports
 * (zig/src/log.zig, zig/src/probe.zig, linked as the log_port/probe_port
 * objects exposing zig_log_* / zig_probe_*).
 *
 * Formerly a ONE-PROCESS C-vs-Zig differential (the C originals lived in
 * src/fx_log.c + src/fx_probe.c, now removed); the last pre-deletion live
 * run (2026-08-29) was byte-identical over the whole script — 346 checks,
 * 0 failed — and the goldens pinned afterwards are that verified behavior.
 *
 * The driver reruns the IDENTICAL scripted emit / grep / search / rotate
 * sequence (the tests/log_test.c contract plus extra
 * tokenize/dup-msg/empty-msg coverage) on the Zig log port against the
 * vendored C engine (fxengine static lib — the engine stays C), and
 * compares every relation dump, grep/search collect buffer, and rc against
 * the pinned goldens (zig/golden/log_probe/).  The probe part rebuilds the
 * probe fixture tree byte-for-byte from the old tests/probe_test.c,
 * refreshes, and compares the relation dumps the same way.  The absolute
 * log_test.c / probe_test.c assertion replays (counts, tuple columns,
 * rotation arithmetic) stay as inline CHECKs — they were the C contract.
 *
 * Machine-varying inputs are EXCLUDED from the goldens (the live C-vs-Zig
 * era asserted them in-process, where both sides saw the same values):
 *   - the env relation (a dump of this process's environ)
 *   - the kernel relation's version/release columns (real uname(2))
 *   - the fs relation's fstype column (whatever /tmp is mounted as)
 * Fixture-derived content (log DBs, process/file/device/net tuples,
 * kernel load/uptime/meminfo/hostname) is fully pinned.
 *
 * Usage: log_probe_live --pin|--check <golden-dir>   (check is the default
 * fxctl_diff.sh/log_probe_diff.sh mode; --pin re-captures goldens from the
 * Zig side — NOT a C oracle rebuild, the C oracle no longer exists).
 */
#include "dl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>

/* the fx_log_cb shape (was fx_log.h; the header left with the C oracle) */
typedef int (*fx_log_cb)(uint32_t ts, const char *svc, const char *level,
                         const char *msg, void *user);

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
static const char *g_golden;
static int g_pin;

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
 * with qsort.  colmask selects which columns are emitted (bit i => column i);
 * the machine-varying columns are filtered out for the golden dumps (see
 * the file header).  Returns a malloc'd buffer (never NULL). */
static char *dump_rel(struct dl_db *db, const char *rel, uint8_t arity,
                      uint32_t symmask, uint32_t colmask, size_t *out_len) {
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
                if (!(colmask & (1u << i))) continue;
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
    { "log", 4, 0xEu, 0xFu }, { "__postings__", 2, 0x0u, 0x3u }
static const struct { const char *rel; uint8_t arity; uint32_t symmask, colmask; } log_rels[] = { LOG_RELS };
/* probe relations, with the machine-varying columns masked OUT:
 *   fs     col1 = fstype (whatever /tmp is mounted as); cols 2-4 = capacity
 *          numbers of the REAL backing filesystems (block counts move as the
 *          host fs fills) — only the path column is pinnable
 *   kernel col0/col1 = version/release (real uname(2))
 *   env    machine environ — masked out entirely
 */
static const struct { const char *rel; uint8_t arity; uint32_t symmask, colmask; } rt_rels[] = {
    { "process", 6, 0x18u, 0x3Fu },  /* comm, state — all columns */
    { "fs", 5, 0x03u, 0x01u },       /* path only (fstype + capacity dropped) */
    { "file", 6, 0x01u, 0x1Fu },     /* path..gid (col5 = live mtime epoch dropped) */
    { "device", 5, 0x09u, 0x1Fu },   /* name, type — all columns */
    { "kernel", 7, 0x07u, 0x7Cu },   /* hostname + numerics (uname cols dropped) */
    { "net", 6, 0x0Fu, 0x3Fu },      /* iface, addr, mac, state — all columns */
    { "env", 2, 0x03u, 0x0u },       /* machine environ — nothing pinned */
};

static void dump_db(const struct { const char *rel; uint8_t arity; uint32_t symmask, colmask; } *specs,
                    size_t nspecs, struct dl_db *db, Buf *out) {
    for (size_t i = 0; i < nspecs; i++) {
        size_t len = 0;
        char *d;
        if (specs[i].colmask == 0) continue; /* fully machine-varying: no lines at all */
        d = dump_rel(db, specs[i].rel, specs[i].arity, specs[i].symmask,
                     specs[i].colmask, &len);
        bput(out, "%s", d);
        free(d);
    }
}

/* golden comparison: --pin writes Buf to <golden-dir>/<name>, --check
 * byte-compares Buf against the pinned file */
static void golden_buf(const char *what, const Buf *b, const char *name) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", g_golden, name);
    checks++;
    if (g_pin) {
        FILE *f = fopen(path, "wb");
        if (!f) { fprintf(stderr, "cannot write %s\n", path); exit(2); }
        fwrite(b->s ? b->s : "", 1, b->len, f);
        fclose(f);
        printf("    PIN %s (%zu bytes)\n", what, b->len);
        return;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        fails++;
        printf("FAIL %s: golden missing (%s)\n", what, path);
        return;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *g = malloc((size_t)n + 1);
    if (!g) { fprintf(stderr, "OOM\n"); exit(2); }
    size_t got = fread(g, 1, (size_t)n, f);
    fclose(f);
    if ((long)got == n && (long)b->len == n &&
        (n == 0 || memcmp(g, b->s, b->len) == 0)) {
        printf("    OK %s (%zu bytes match golden)\n", what, b->len);
    } else {
        fails++;
        printf("FAIL %s differs (golden=%ld bytes, actual=%zu bytes)\n", what, n, b->len);
        if (b->s && got == b->len) {
            size_t i = 0;
            while (i < b->len && g[i] == b->s[i]) i++;
            size_t lo = i > 40 ? i - 40 : 0;
            size_t w = i - lo + 40;
            printf("    first diff at byte %zu\n    gol: <<%.*s>>\n    act: <<%.*s>>\n",
                   i, (int)(w < (size_t)n - lo ? w : (size_t)n - lo), g + lo,
                   (int)(w < b->len - lo ? w : b->len - lo), b->s + lo);
        }
    }
    free(g);
}

/* golden comparison for a (rc, collected-bytes) pair lives in battery()
 * below: pins rc and the collected buffer as <name>.rc / <name>.collect */

/* ─── log collect callback (same shape as the old tests/log_test.c) ─────── */

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

/* run one grep/search battery case: rc + collect buffer vs goldens, plus
 * an optional absolute assertion on rc */
static void battery(const char *slug, const char *what, long rz, const Collect *z,
                    int has_expect, long expect) {
    char name[256];
    Buf rcbuf = {0}, cbuf = {0};
    bput(&rcbuf, "%ld\n", rz);
    cbuf.s = z->buf; cbuf.len = z->off; /* borrow */
    golden_buf(what, &rcbuf, (snprintf(name, sizeof name, "%s.rc", slug), name));
    golden_buf(what, &cbuf, (snprintf(name, sizeof name, "%s.collect", slug), name));
    checks++;
    if (rz >= 0 && (long)z->n != rz) {
        fails++;
        printf("FAIL %s: rc=%ld but %ld lines collected\n", what, rz, z->n);
    } else {
        printf("    OK %s (rc=%ld)\n", what, rz);
    }
    if (has_expect) {
        CHECK(rz == expect, "REPLAY log_test: %s == %ld (got %ld)", what, expect, rz);
    }
}

/* ─── fixture helpers (from the old tests/probe_test.c) ──────────────────── */

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
    char dbz[512];
    snprintf(dbz, sizeof dbz, "/tmp/fxlogZ-XXXXXX");
    if (!mkdtemp(dbz)) { fprintf(stderr, "mkdtemp failed\n"); exit(2); }

    struct dl_db *z = zig_log_open(dbz);
    CHECK(z != NULL, "zig_log_open");
    if (!z) exit(2);

    /* the log_test.c emit script (4 base lines) */
    CHECK(zig_log_emit(z, 100, "svcA", "info", "starting up") == 0, "zig emit 1");
    CHECK(zig_log_emit(z, 101, "svcA", "info", "heartbeat ok") == 0, "zig emit 2");
    CHECK(zig_log_emit(z, 102, "svcB", "error", "heartbeat ok") == 0, "zig emit 3");
    CHECK(zig_log_emit(z, 103, "svcA", "info", "shutting down") == 0, "zig emit 4");
    CHECK(zig_log_count(z) == 4, "REPLAY log_test: zig count==4 (got %llu)",
          (unsigned long long)zig_log_count(z));

    /* checkpoint 1 dump */
    Buf dz1 = {0};
    dump_db(log_rels, 2, z, &dz1);
    golden_buf("log dump after 4 emits (log+__postings__)", &dz1, "log-dump-1.out");

    /* grep battery (log_test: heartbeat==2, starting==1) */
    Collect gz = {0};
    long rz = zig_log_grep(z, "heartbeat", collect_cb, &gz);
    battery("grep-heartbeat", "grep heartbeat", rz, &gz, 1, 2);

    Collect gz2 = {0};
    rz = zig_log_grep(z, "starting", collect_cb, &gz2);
    battery("grep-starting", "grep starting", rz, &gz2, 1, 1);

    /* search battery (log_test: 2 / 1 / 0) */
    const char *terms1[] = { "heartbeat", "ok" };
    Collect sz1 = {0};
    rz = zig_log_search(z, terms1, 2, collect_cb, &sz1);
    battery("search-heartbeat-ok", "search heartbeat AND ok", rz, &sz1, 1, 2);

    const char *terms2[] = { "shutting" };
    Collect sz2 = {0};
    rz = zig_log_search(z, terms2, 1, collect_cb, &sz2);
    battery("search-shutting", "search shutting", rz, &sz2, 1, 1);

    const char *terms3[] = { "starting", "down" };
    Collect sz3 = {0};
    rz = zig_log_search(z, terms3, 2, collect_cb, &sz3);
    battery("search-starting-down", "search starting AND down", rz, &sz3, 1, 0);

    /* error paths: NULL db, empty terms — absolute rc contract.
     * NOTE: the bad-REGEX path ("(") is deliberately NOT exercised here:
     * the vendored engine's regex_compile parse-error path calls
     * dsm_free(&dsm) on a never-initialized stack struct (dsm_init runs
     * only after a successful parse; dsm_free only NULL-checks entries),
     * so the outcome depends on stale stack bytes — observed SIGILL under
     * one stack layout and silent success under another.  The contract
     * (bad regex -> rc < 0) was C-verified in the last pre-deletion live
     * run; the engine bug itself is reported upstream-side (reachable
     * from fxctl grep with a malformed pattern, C and Zig alike). */
    CHECK(zig_log_grep(NULL, "x", collect_cb, NULL) == -1, "REPLAY: zig grep NULL db");
    CHECK(zig_log_search(z, NULL, 0, collect_cb, &gz) == -1, "REPLAY: zig search nterms=0");
    CHECK(zig_log_count(NULL) == UINT64_MAX, "REPLAY: zig count NULL db");
    CHECK(zig_log_rotate(NULL, 1) == -1, "REPLAY: zig rotate NULL db");

    /* rotation: cap=2 -> drop oldest quarter (4/4=1) => 3 remain */
    CHECK(zig_log_rotate(z, 2) == 0, "zig rotate cap=2");
    CHECK(zig_log_count(z) == 3, "REPLAY log_test: zig count==3 after rotate (got %llu)",
          (unsigned long long)zig_log_count(z));

    Buf dz2 = {0};
    dump_db(log_rels, 2, z, &dz2);
    golden_buf("log dump after rotate cap=2", &dz2, "log-dump-2.out");

    /* no-op rotate: cap >= n -> 0, count unchanged */
    CHECK(zig_log_rotate(z, 1000) == 0, "noop rotate rc");

    zig_log_close(z);

    /* reopen — relations persist and are re-declarable */
    z = zig_log_open(dbz);
    CHECK(z != NULL, "reopen after rotate");
    CHECK(zig_log_count(z) == 3,
          "REPLAY log_test: reopen count==3 (zig=%llu)",
          (unsigned long long)zig_log_count(z));

    /* larger batch rotation exercises collect-then-delete (log_test:
     * 100 fresh lines -> 103 total; rotate cap=20 -> drop 25 -> 78;
     * ts 222 survives, ts 200 dropped) */
    for (uint32_t t = 200; t < 300; t++) {
        char msg[32];
        snprintf(msg, sizeof msg, "batch line %u", t);
        CHECK(zig_log_emit(z, t, "batch", "info", msg) == 0, "zig emit batch %u", t);
    }
    CHECK(zig_log_count(z) == 103, "REPLAY log_test: zig count==103 (got %llu)",
          (unsigned long long)zig_log_count(z));
    CHECK(zig_log_rotate(z, 20) == 0, "zig rotate cap=20");
    CHECK(zig_log_count(z) == 78,
          "REPLAY log_test: count==78 after batch rotate (zig=%llu)",
          (unsigned long long)zig_log_count(z));

    Collect bz = {0};
    rz = zig_log_grep(z, "batch line 222", collect_cb, &bz);
    battery("grep-batch-222", "grep batch line 222 (survivor)", rz, &bz, 1, 1);

    Collect bz2 = {0};
    rz = zig_log_grep(z, "batch line 200", collect_cb, &bz2);
    battery("grep-batch-200", "grep batch line 200 (dropped)", rz, &bz2, 1, 0);

    /* extra coverage beyond log_test: dup msg across svc, tokenize-heavy,
     * punctuation-only, empty msg, then regex/search battery #2 */
    CHECK(zig_log_emit(z, 106, "svcB", "warn", "starting up") == 0, "zig emit dup");
    CHECK(zig_log_emit(z, 107, "svcC", "info", "Multi Word Tokens: hello_world 42") == 0, "zig emit tokens");
    CHECK(zig_log_emit(z, 108, "svcD", "info", "!@# $%^ &*()") == 0, "zig emit punct");
    CHECK(zig_log_emit(z, 109, "svcE", "info", "") == 0, "zig emit empty");

    Buf dz3 = {0};
    dump_db(log_rels, 2, z, &dz3);
    golden_buf("log dump after extra emits (tokenize/postings parity)", &dz3, "log-dump-3.out");

    /* regex battery #2: classes, alternation, anchored literal, empty regex */
    const char *regexes[] = { "hello_world", "w[oO]rd", "heartbeat|starting",
                              "^starting", "batch line 2[0-9][0-9]", "",
                              "svcE.*never", "42" };
    const char *re_slugs[] = { "re-hello", "re-class", "re-alt", "re-anchored",
                               "re-batch-2xx", "re-empty", "re-svcE-never", "re-42" };
    for (size_t i = 0; i < sizeof regexes / sizeof *regexes; i++) {
        Collect xz = {0};
        rz = zig_log_grep(z, regexes[i], collect_cb, &xz);
        battery(re_slugs[i], "regex battery", rz, &xz, 0, 0);
    }

    /* search battery #2: multi-word AND, single common term */
    const char *t4[] = { "multi", "word" };
    Collect sz4 = {0};
    rz = zig_log_search(z, t4, 2, collect_cb, &sz4);
    battery("search-multi-word", "search multi AND word", rz, &sz4, 0, 0);

    const char *t5[] = { "line" };
    Collect sz5 = {0};
    rz = zig_log_search(z, t5, 1, collect_cb, &sz5);
    battery("search-line", "search line", rz, &sz5, 0, 0);

    Buf dz4 = {0};
    dump_db(log_rels, 2, z, &dz4);
    golden_buf("final log dump after battery", &dz4, "log-dump-4.out");

    zig_log_close(z);
    free(dz1.s); free(dz2.s); free(dz3.s); free(dz4.s);
    /* DB leaves WAL files; ignore the rmdir failure */
    rmdir(dbz);
}

/* ─── part 2: probe ──────────────────────────────────────────────────────── */

static void probe_part(void) {
    char root[512];
    snprintf(root, sizeof root, "/tmp/fxprobe-XXXXXX");
    if (!mkdtemp(root)) { fprintf(stderr, "mkdtemp failed\n"); exit(2); }

    /* ── fixture tree, byte-for-byte from the old tests/probe_test.c ── */
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

    /* ── DB on the SAME fixture root ── */
    char dbz[600];
    snprintf(dbz, sizeof dbz, "%s/db-z", root);
    mkp(dbz);
    struct dl_db *z = dl_open(dbz);
    CHECK(z != NULL, "probe dl_open");
    if (!z) exit(2);

    CHECK(zig_probe_declare(z) == 0, "REPLAY: zig_probe_declare(z) == 0");
    CHECK(zig_probe_declare(z) == 0, "declare idempotent");

    char errz[256];
    snprintf(errz, sizeof errz, "OK");
    int rz = zig_probe_refresh(z, root, errz, sizeof errz);
    CHECK(rz == 0, "refresh rc (zig=%d '%s')", rz, errz);
    /* on success the C contract leaves err UNTOUCHED — must still be the sentinel */
    CHECK(strcmp(errz, "OK") == 0, "refresh err untouched on success (zig='%s')", errz);

    /* dump the fixture-determined relations (machine-varying columns
     * masked out — see rt_rels), vs goldens */
    Buf dz = {0};
    dump_db(rt_rels, 7, z, &dz);
    golden_buf("probe dump refresh#1 (fixture relations)", &dz, "probe-dump-1.out");

    /* REPLAY probe_test.c assertions against the ZIG DB */
    CHECK(dl_count(z, "process") == 2, "REPLAY probe_test: zig process count == 2 (got %llu)",
          (unsigned long long)dl_count(z, "process"));
    uint32_t zz[8];
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

    /* idempotent re-refresh: counts stable, dump identical again */
    rz = zig_probe_refresh(z, root, errz, sizeof errz);
    CHECK(rz == 0, "refresh#2 rc");
    CHECK(dl_count(z, "process") == 2,
          "REPLAY probe_test: process count still 2 after re-refresh");
    CHECK(dl_count(z, "net") == 2,
          "REPLAY probe_test: net count still 2 after re-refresh");
    dz.len = 0;
    dump_db(rt_rels, 7, z, &dz);
    golden_buf("probe dump refresh#2 (idempotent)", &dz, "probe-dump-2.out");

    free(dz.s);
    dl_close(z);
}

int main(int argc, char **argv) {
    if (argc < 2 || (strcmp(argv[1], "pin") != 0 && strcmp(argv[1], "check") != 0)) {
        fprintf(stderr, "usage: log_probe_live pin|check <golden-dir>\n");
        return 2;
    }
    g_pin = (strcmp(argv[1], "pin") == 0);
    g_golden = argv[2];
    printf("== part 1: fx_log regression (Zig port vs goldens) ==\n");
    log_part();
    printf("== part 2: fx_probe regression (Zig port vs goldens) ==\n");
    probe_part();
    printf("log_probe_live: %d checks, %d failed\n", checks, fails);
    return fails ? 1 : 0;
}
