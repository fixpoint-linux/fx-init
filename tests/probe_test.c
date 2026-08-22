/* tests/probe_test.c — unit test for src/fx_probe.c (the OS probe loop).
 *
 * Builds a fixture /proc + /sys + /etc tree in a tmp dir, runs
 * fx_probe_refresh against it, and asserts the probe relations.  Links:
 * probe_test.c + src/fx_probe.c + datalog-dafsa + dafsa (NO fxstore, NO dhall-c).
 *
 * Build (see tests/build_probe.sh):
 *   cosmocc -std=c11 -O2 -g -Wall -Wextra -I src -I vendor/datalog-dafsa/src \
 *     -I vendor/datalog-dafsa/vendor -I vendor/dafsa -o build-tmp/probe_test \
 *     tests/probe_test.c src/fx_probe.c <datalog-dafsa engine> <dafsa>
 *
 * Usage: probe_test   (uses a mkdtemp fixture root)
 */
#include "fx_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>

static int fails = 0, passes = 0;
#define OK(cond, ...) do { if (cond) { passes++; } else { fails++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* mkdir -p helper */
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

/* write a file (creating parent dirs) */
static void wf(const char *path, const char *content) {
    /* create parent dirs only (strip the filename component) */
    char dir[1024];
    snprintf(dir, sizeof dir, "%s", path);
    char *sl = strrchr(dir, '/');
    if (sl) { *sl = '\0'; mkp(dir); }
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path); return; }
    fputs(content, f);
    fclose(f);
}

/* count tuples of a relation */
static uint64_t rel_count(struct dl_db *db, const char *rel) {
    return dl_count(db, rel);
}

/* find a process tuple by pid; fills cols[6].  Returns 1 if found. */
static int find_process(struct dl_db *db, uint32_t pid, uint32_t cols[6]) {
    dl_iter *it = dl_iter_open(db, "process", &pid, 1);
    if (!it) return 0;
    int got = (dl_iter_next(it, cols) == 1) ? 1 : 0;
    dl_iter_close(it);
    return got;
}

/* find a net tuple by iface name (interned).  Returns 1 if found. */
static int find_net(struct dl_db *db, const char *iface, uint32_t cols[6]) {
    uint32_t isym = dl_intern_str(db, iface);
    if (!isym) return 0;
    dl_iter *it = dl_iter_open(db, "net", &isym, 1);
    if (!it) return 0;
    int got = (dl_iter_next(it, cols) == 1) ? 1 : 0;
    dl_iter_close(it);
    return got;
}

int main(void) {
    /* fixture root */
    char root[512];
    snprintf(root, sizeof root, "/workspace/fx-init/build-tmp/probe-XXXXXX");
    if (!mkdtemp(root)) { fprintf(stderr, "mkdtemp failed\n"); return 2; }

    /* ─── build the fixture tree ─── */
    /* /proc/1/stat — 22 fields after ')'; rss at index 21 = 100 pages */
    char p[700];
    snprintf(p, sizeof p, "%s/proc/1/stat", root);
    wf(p, "1 (init) S 0 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 100 4096 100\n");
    snprintf(p, sizeof p, "%s/proc/1/status", root);
    wf(p, "Uid:\t0\t0\t0\t0\n");
    /* /proc/100/stat — comm has spaces ("worker process"); ppid=1; rss=256 */
    snprintf(p, sizeof p, "%s/proc/100/stat", root);
    wf(p, "100 (worker process) R 1 0 0 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 200 8192 256\n");
    snprintf(p, sizeof p, "%s/proc/100/status", root);
    wf(p, "Uid:\t1000\t1000\t1000\t1000\n");

    /* /sys/class/net/lo/ */
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
    /* /sys/class/net/eth0/ */
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

    /* /proc/loadavg, /proc/meminfo, /proc/uptime */
    snprintf(p, sizeof p, "%s/proc/loadavg", root);
    wf(p, "0.42 0.20 0.30 1/100 1234\n");
    snprintf(p, sizeof p, "%s/proc/meminfo", root);
    wf(p, "MemTotal: 2048 kB\nMemFree: 1024 kB\n");
    snprintf(p, sizeof p, "%s/proc/uptime", root);
    wf(p, "12345.67 67890.12\n");

    /* /etc/hostname */
    snprintf(p, sizeof p, "%s/etc/hostname", root);
    wf(p, "fixbox\n");

    /* ─── DB + probe ─── */
    char dbdir[600];
    snprintf(dbdir, sizeof dbdir, "%s/db", root);
    mkp(dbdir);
    struct dl_db *db = dl_open(dbdir);
    OK(db != NULL, "dl_open");
    OK(fx_probe_declare(db) == 0, "fx_probe_declare");

    char err[256];
    OK(fx_probe_refresh(db, root, err, sizeof err) == 0, "fx_probe_refresh (%s)", err);

    /* process: 2 tuples */
    OK(rel_count(db, "process") == 2, "process count == 2 (got %llu)",
       (unsigned long long)rel_count(db, "process"));

    uint32_t c[8];
    OK(find_process(db, 1, c) == 1, "find pid 1");
    if (find_process(db, 1, c) == 1) {
        OK(c[0] == 1 && c[1] == 0 && c[2] == 0, "pid1 pid/ppid/uid");
        OK(!strcmp(dl_intern_str_of(db, c[3]), "init"), "pid1 comm == init (got %s)",
           dl_intern_str_of(db, c[3]));
        OK(!strcmp(dl_intern_str_of(db, c[4]), "S"), "pid1 state == S");
        OK(c[5] == 400, "pid1 rss_kb == 400 (got %u)", c[5]);
    }
    OK(find_process(db, 100, c) == 1, "find pid 100");
    if (find_process(db, 100, c) == 1) {
        OK(c[0] == 100 && c[1] == 1 && c[2] == 1000, "pid100 pid/ppid/uid");
        OK(!strcmp(dl_intern_str_of(db, c[3]), "worker process"),
           "pid100 comm (spaces) == 'worker process' (got '%s')",
           dl_intern_str_of(db, c[3]));
        OK(!strcmp(dl_intern_str_of(db, c[4]), "R"), "pid100 state == R");
        OK(c[5] == 1024, "pid100 rss_kb == 1024 (got %u)", c[5]);
    }

    /* net: 2 tuples; device: 2 tuples */
    OK(rel_count(db, "net") == 2, "net count == 2 (got %llu)",
       (unsigned long long)rel_count(db, "net"));
    OK(rel_count(db, "device") == 2, "device count == 2 (got %llu)",
       (unsigned long long)rel_count(db, "device"));
    if (find_net(db, "lo", c) == 1) {
        OK(c[4] == 1234 && c[5] == 5678, "net lo rx=1234 tx=5678 (got %u/%u)",
           c[4], c[5]);
    }
    if (find_net(db, "eth0", c) == 1) {
        OK(c[4] == 9999 && c[5] == 1111, "net eth0 rx=9999 tx=1111");
    }

    /* kernel: 1 tuple with memtotal=2048, memfree=1024, load1=42 */
    OK(rel_count(db, "kernel") == 1, "kernel count == 1");
    dl_iter *it = dl_iter_open(db, "kernel", NULL, 0);
    if (it && dl_iter_next(it, c) == 1) {
        OK(c[5] == 2048, "kernel memtotal == 2048 (got %u)", c[5]);
        OK(c[6] == 1024, "kernel memfree == 1024 (got %u)", c[6]);
        OK(c[4] == 42, "kernel load1_x100 == 42 (got %u)", c[4]);
        OK(c[3] == 12345, "kernel uptime == 12345 (got %u)", c[3]);
    } else {
        OK(0, "kernel tuple readable");
    }
    if (it) dl_iter_close(it);

    /* file: /etc/hostname present */
    OK(rel_count(db, "file") == 1, "file count == 1 (got %llu)",
       (unsigned long long)rel_count(db, "file"));

    /* env: real environ has > 0 entries */
    OK(rel_count(db, "env") > 0, "env count > 0 (got %llu)",
       (unsigned long long)rel_count(db, "env"));

    /* idempotent re-refresh: counts stable (delete-all + re-add) */
    OK(fx_probe_refresh(db, root, err, sizeof err) == 0, "second refresh");
    OK(rel_count(db, "process") == 2, "process count still 2 after re-refresh");
    OK(rel_count(db, "net") == 2, "net count still 2 after re-refresh");

    dl_close(db);
    printf("probe_test: %d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
