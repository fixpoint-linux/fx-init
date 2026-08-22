/* tests/log_test.c — unit test for src/fx_log.c (the DAFSA-interned log DB).
 *
 * Links: tests/log_test.c + src/fx_log.c + datalog-dafsa + dafsa (NO fxstore,
 * NO dhall-c).  Creates a throwaway DB, emits lines, exercises grep/search/
 * rotate, asserts counts and content.
 *
 * Build (see tests/build_log.sh):
 *   cosmocc -std=c11 -O2 -g -Wall -Wextra -I src -I vendor/datalog-dafsa/src \
 *     -I vendor/datalog-dafsa/vendor -I vendor/dafsa -o build-tmp/log_test \
 *     tests/log_test.c src/fx_log.c <datalog-dafsa engine> <dafsa>
 *
 * Usage: log_test [dbdir]   (default build-tmp/logdb-test)
 */
#include "fx_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fails = 0, passes = 0;
#define OK(cond, ...) do { if (cond) { passes++; } else { fails++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* Collect emitted lines into a fixed buffer for assertions. */
typedef struct {
    char buf[8192];
    size_t off;
    int n;
} Collect;

static int collect_cb(uint32_t ts, const char *svc, const char *level,
                       const char *msg, void *user) {
    Collect *c = (Collect *)user;
    c->n++;
    int w = snprintf(c->buf + c->off, sizeof c->buf - c->off,
                     "%u\t%s\t%s\t%s\n", ts, svc, level, msg);
    if (w > 0) c->off += (size_t)w;
    return 0;
}

int main(int argc, char **argv) {
    char dbdir[512];
    if (argc > 1) {
        strncpy(dbdir, argv[1], sizeof dbdir - 1);
        dbdir[sizeof dbdir - 1] = '\0';
        mkdir(dbdir, 0755);  /* ignore EEXIST */
    } else {
        /* fresh unique dir per run via mkdtemp (no shell system() — APE's
         * bundled tools differ from host coreutils) */
        snprintf(dbdir, sizeof dbdir, "/tmp/fxlog-XXXXXX");
        if (!mkdtemp(dbdir)) { fprintf(stderr, "mkdtemp failed\n"); return 2; }
    }

    struct dl_db *db = fx_log_open(dbdir);
    OK(db != NULL, "fx_log_open");

    /* emit several lines — note repeated msg collapses to one sym */
    OK(fx_log_emit(db, 100, "svcA", "info", "starting up") == 0, "emit 1");
    OK(fx_log_emit(db, 101, "svcA", "info", "heartbeat ok") == 0, "emit 2");
    OK(fx_log_emit(db, 102, "svcB", "error", "heartbeat ok") == 0, "emit 3 (dup msg)");
    OK(fx_log_emit(db, 103, "svcA", "info", "shutting down") == 0, "emit 4");

    OK(fx_log_count(db) == 4, "count==4 (got %llu)", (unsigned long long)fx_log_count(db));

    /* grep: substring 'heartbeat' should match 2 lines */
    Collect g = {0};
    long gn = fx_log_grep(db, "heartbeat", collect_cb, &g);
    OK(gn == 2, "grep heartbeat == 2 (got %ld)", gn);
    OK(strstr(g.buf, "svcA") && strstr(g.buf, "svcB"), "grep content has both svcs");
    OK(strstr(g.buf, "error") != NULL, "grep content has error level");

    /* grep: full anchored via .* wrapping — 'starting' substring */
    Collect g2 = {0};
    long gn2 = fx_log_grep(db, "starting", collect_cb, &g2);
    OK(gn2 == 1, "grep starting == 1 (got %ld)", gn2);

    /* search: AND of 'heartbeat' + 'ok' — msg 'heartbeat ok' matches */
    const char *terms[] = { "heartbeat", "ok" };
    Collect s = {0};
    long sn = fx_log_search(db, terms, 2, collect_cb, &s);
    OK(sn == 2, "search heartbeat AND ok == 2 (got %ld)", sn);

    /* search: single term 'shutting' */
    const char *t2[] = { "shutting" };
    Collect s2 = {0};
    long sn2 = fx_log_search(db, t2, 1, collect_cb, &s2);
    OK(sn2 == 1, "search shutting == 1 (got %ld)", sn2);

    /* search: AND of terms that never co-occur in one message -> 0 */
    const char *t3[] = { "starting", "down" };
    Collect s3 = {0};
    long sn3 = fx_log_search(db, t3, 2, collect_cb, &s3);
    OK(sn3 == 0, "search starting AND down == 0 (got %ld)", sn3);

    /* rotation: cap=2 -> drop oldest quarter (4/4=1) => 3 remain */
    OK(fx_log_rotate(db, 2) == 0, "rotate cap=2");
    OK(fx_log_count(db) == 3, "after rotate count==3 (got %llu)",
       (unsigned long long)fx_log_count(db));

    fx_log_close(db);

    /* reopen — relations should persist and be re-declarable (idempotent) */
    db = fx_log_open(dbdir);
    OK(db != NULL, "reopen after rotate");
    OK(fx_log_count(db) == 3, "reopen count==3");
    fx_log_close(db);

    printf("log_test: %d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
