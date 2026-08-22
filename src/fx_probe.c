/* fx_probe.c — (U-C2) the init-hosted OS probe loop.
 *
 * fx_probe_refresh rebuilds the probe relations from /proc, /sys, statvfs,
 * uname, and environ inside a single transaction.  See fx_probe.h.
 *
 * `root` is a test-only fixture root that redirects /proc, /sys, /etc reads.
 * fs (statvfs) and uname always hit the real system (no fixture) and skip
 * gracefully on failure — the unit test focuses on process/net/kernel/env,
 * which ARE fixture-driven.  Robustness: every source read that fails is
 * skipped (a probe that errors on one entry still reports the rest). */
#include "fx_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <time.h>
#include <ctype.h>

extern char **environ;

/* ─── helpers ────────────────────────────────────────────────────────────── */

/* Build "<root><sub>" (root may be "" for real system) into out. */
static void pfx(char *out, size_t cap, const char *root, const char *sub) {
    if (root && root[0])
        snprintf(out, cap, "%s%s", root, sub);
    else
        snprintf(out, cap, "%s", sub);
}

/* read a small file fully into a malloc'd buffer (NUL-terminated). */
static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *buf = malloc(65536);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, 65535, f);
    fclose(f);
    buf[n] = '\0';
    return buf;
}

/* first integer token in `s` (strtoul). */
static uint32_t first_u32(const char *s) {
    while (*s && !isdigit((unsigned char)*s)) s++;
    return (uint32_t)strtoul(s, NULL, 10);
}

/* delete-all existing tuples of `rel` (collect then delete — safe vs the live
 * DAFSA cursor).  Must be called inside an open txn. */
static int clear_rel(struct dl_db *db, const char *rel, uint8_t arity) {
    dl_iter *it = dl_iter_open(db, rel, NULL, 0);
    if (!it) return 0;  /* absent/empty: fine */
    if (dl_iter_arity(it) != arity) { dl_iter_close(it); return -1; }
    /* collect all tuples */
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

/* add one fact with mixed interned/raw columns.  `cols` carries raw u32 for
 * numeric slots and the interned sym for string slots; the caller interns. */
static void add(struct dl_db *db, const char *rel, const uint32_t *cols, uint8_t ar) {
    dl_txn_add_fact(db, rel, cols, ar);
}

static uint32_t sym(struct dl_db *db, const char *s) {
    uint32_t r = dl_intern_str(db, s);
    return r ? r : 1;  /* 1 is always at least the empty/first sym */
}

/* ─── process <- /proc/[0-9]+/{stat,status} ──────────────────────────────── */

static int is_pid_dir(const char *name) {
    if (!name[0] || !isdigit((unsigned char)name[0])) return 0;
    for (const char *p = name; *p; p++)
        if (!isdigit((unsigned char)*p)) return 0;
    return 1;
}

static void probe_process(struct dl_db *db, const char *root) {
    char proc[512];
    pfx(proc, sizeof proc, root, "/proc");
    clear_rel(db, "process", 6);
    DIR *d = opendir(proc);
    if (!d) return;
    long pgkb = sysconf(_SC_PAGESIZE) / 1024;
    if (pgkb <= 0) pgkb = 4;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!is_pid_dir(e->d_name)) continue;
        char path[1100];
        /* /proc/<pid>/stat: pid (comm) state ppid ... rss */
        snprintf(path, sizeof path, "%s/%s/stat", proc, e->d_name);
        char *stat = read_file(path);
        if (!stat) continue;
        uint32_t pid = (uint32_t)strtoul(e->d_name, NULL, 10);
        /* find last ')' to skip comm (may contain spaces) */
        char *cp = strrchr(stat, ')');
        if (!cp) { free(stat); continue; }
        cp++;  /* past ')' */
        /* tokenize the remainder */
        char *save = NULL;
        char *tok_state = strtok_r(cp, " \t\n", &save);
        /* field indices after ')': 0=state 1=ppid ... 21=rss */
        char *fields[32];
        int nf = 0;
        while (tok_state && nf < 32) {
            fields[nf++] = tok_state;
            tok_state = strtok_r(NULL, " \t\n", &save);
        }
        if (nf < 22) { free(stat); continue; }
        char st = fields[0][0];
        uint32_t ppid = (uint32_t)strtoul(fields[1], NULL, 10);
        /* comm: between '(' and the last ')' */
        char *comm0 = strchr(stat, '(');
        char commbuf[256];
        if (comm0 && cp > comm0) {
            size_t L = (size_t)(cp - 1 - (comm0 + 1));
            if (L >= sizeof commbuf) L = sizeof commbuf - 1;
            memcpy(commbuf, comm0 + 1, L);
            commbuf[L] = '\0';
        } else {
            snprintf(commbuf, sizeof commbuf, "%u", pid);
        }
        uint32_t rss = (uint32_t)strtoul(fields[21], NULL, 10);
        uint32_t rss_kb = rss * (uint32_t)pgkb;
        free(stat);
        /* uid from /proc/<pid>/status Uid: line */
        uint32_t uid = 0;
        snprintf(path, sizeof path, "%s/%s/status", proc, e->d_name);
        char *status = read_file(path);
        if (status) {
            char *u = strstr(status, "Uid:");
            if (u) uid = first_u32(u + 4);
            free(status);
        }
        char stbuf[2] = { st, '\0' };
        uint32_t cols[6] = { pid, ppid, uid, sym(db, commbuf), sym(db, stbuf), rss_kb };
        add(db, "process", cols, 6);
    }
    closedir(d);
}

/* ─── fs <- statvfs on {/, /run, /fx/store} ──────────────────────────────── */

static void probe_fs(struct dl_db *db) {
    clear_rel(db, "fs", 5);
    const char *paths[] = { "/", "/run", "/fx/store" };
    const char *fts[]   = { "rootfs", "tmpfs", "store" };
    for (int i = 0; i < 3; i++) {
        struct statvfs v;
        if (statvfs(paths[i], &v) != 0) continue;
        unsigned long bkb = v.f_bsize / 1024;
        if (bkb == 0) bkb = 1;
        uint32_t total = (uint32_t)(v.f_blocks * bkb);
        uint32_t freeb  = (uint32_t)(v.f_bfree  * bkb);
        uint32_t avail  = (uint32_t)(v.f_bavail * bkb);
        uint32_t used   = total - freeb;
        uint32_t cols[5] = { sym(db, paths[i]), sym(db, fts[i]), total, used, avail };
        add(db, "fs", cols, 5);
    }
}

/* ─── file <- stat on {/etc/hostname} (fixture-aware) ────────────────────── */

static void probe_file(struct dl_db *db, const char *root) {
    clear_rel(db, "file", 6);
    char path[512];
    pfx(path, sizeof path, root, "/etc/hostname");
    struct stat sb;
    if (stat(path, &sb) == 0) {
        char *rp = path;
        if (root && root[0]) { /* keep fixture path as-is for tests */ }
        uint32_t cols[6] = { sym(db, "/etc/hostname"),
                             (uint32_t)sb.st_size, (uint32_t)sb.st_mode,
                             (uint32_t)sb.st_uid, (uint32_t)sb.st_gid,
                             (uint32_t)sb.st_mtime };
        add(db, "file", cols, 6);
        (void)rp;
    }
}

/* ─── device + net <- /sys/class/net/<iface>/ ────────────────────────────── */

static void probe_net(struct dl_db *db, const char *root) {
    char sysnet[512];
    pfx(sysnet, sizeof sysnet, root, "/sys/class/net");
    clear_rel(db, "device", 5);
    clear_rel(db, "net", 6);
    DIR *d = opendir(sysnet);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char base[1100];
        snprintf(base, sizeof base, "%s/%s", sysnet, e->d_name);
        /* address (MAC) */
        char p[1300];
        snprintf(p, sizeof p, "%s/address", base);
        char *mac = read_file(p);
        if (mac) { char *nl = strpbrk(mac, "\n\r"); if (nl) *nl = '\0'; if (!mac[0]) { free(mac); mac = NULL; } }
        /* operstate */
        snprintf(p, sizeof p, "%s/operstate", base);
        char *op = read_file(p);
        if (op) { char *nl = strpbrk(op, "\n\r"); if (nl) *nl = '\0'; }
        /* ifindex as minor */
        snprintf(p, sizeof p, "%s/ifindex", base);
        char *idx = read_file(p);
        uint32_t ifindex = idx ? first_u32(idx) : 0;
        if (idx) free(idx);
        /* rx/tx bytes */
        snprintf(p, sizeof p, "%s/statistics/rx_bytes", base);
        char *rx = read_file(p);
        snprintf(p, sizeof p, "%s/statistics/tx_bytes", base);
        char *tx = read_file(p);
        uint32_t rxb = rx ? first_u32(rx) : 0;
        uint32_t txb = tx ? first_u32(tx) : 0;
        const char *m = mac ? mac : "?";
        const char *s = op ? op : "unknown";
        uint32_t cols[6] = { sym(db, e->d_name), sym(db, m), sym(db, m),
                             sym(db, s), rxb, txb };
        add(db, "net", cols, 6);
        /* device entry for the same iface */
        uint32_t dcols[5] = { sym(db, e->d_name), 0, ifindex, sym(db, "net"), 0 };
        add(db, "device", dcols, 5);
        if (mac) free(mac);
        if (op) free(op);
        if (rx) free(rx);
        if (tx) free(tx);
    }
    closedir(d);
}

/* ─── kernel <- uname + /proc/loadavg + /proc/meminfo ────────────────────── */

static void probe_kernel(struct dl_db *db, const char *root) {
    clear_rel(db, "kernel", 7);
    struct utsname u;
    if (uname(&u) != 0) return;
    char p[512];
    /* loadavg: "0.10 0.20 0.30 ..." -> load1 * 100 */
    pfx(p, sizeof p, root, "/proc/loadavg");
    char *la = read_file(p);
    uint32_t load1 = 0;
    if (la) {
        double f = strtod(la, NULL);
        load1 = (uint32_t)(f * 100.0);
        free(la);
    }
    /* meminfo: MemTotal: X kB / MemFree: Y kB */
    pfx(p, sizeof p, root, "/proc/meminfo");
    char *mi = read_file(p);
    uint32_t mt = 0, mf = 0;
    if (mi) {
        char *t = strstr(mi, "MemTotal:");
        if (t) mt = first_u32(t + 9);
        char *fr = strstr(mi, "MemFree:");
        if (fr) mf = first_u32(fr + 8);
        free(mi);
    }
    /* uptime_s from /proc/uptime */
    pfx(p, sizeof p, root, "/proc/uptime");
    char *up = read_file(p);
    uint32_t uptime = 0;
    if (up) { uptime = (uint32_t)strtod(up, NULL); free(up); }
    /* hostname from uname (nodename) — or /etc/hostname already in file */
    uint32_t cols[7] = { sym(db, u.sysname), sym(db, u.release),
                         sym(db, u.nodename), uptime, load1, mt, mf };
    add(db, "kernel", cols, 7);
}

/* ─── env <- environ snapshot ─────────────────────────────────────────────── */

static void probe_env(struct dl_db *db) {
    clear_rel(db, "env", 2);
    for (char **ep = environ; *ep; ep++) {
        char *eq = strchr(*ep, '=');
        if (!eq) continue;
        size_t kl = (size_t)(eq - *ep);
        char key[512];
        if (kl >= sizeof key) kl = sizeof key - 1;
        memcpy(key, *ep, kl);
        key[kl] = '\0';
        uint32_t cols[2] = { sym(db, key), sym(db, eq + 1) };
        add(db, "env", cols, 2);
    }
}

/* ─── public API ──────────────────────────────────────────────────────────── */

int fx_probe_declare(struct dl_db *rt) {
    if (!rt) return -1;
    if (dl_declare_relation(rt, "process", 6) != 0) return -1;
    if (dl_declare_relation(rt, "fs", 5) != 0) return -1;
    if (dl_declare_relation(rt, "file", 6) != 0) return -1;
    if (dl_declare_relation(rt, "device", 5) != 0) return -1;
    if (dl_declare_relation(rt, "kernel", 7) != 0) return -1;
    if (dl_declare_relation(rt, "net", 6) != 0) return -1;
    if (dl_declare_relation(rt, "env", 2) != 0) return -1;
    return 0;
}

int fx_probe_refresh(struct dl_db *rt, const char *root,
                     char *err, size_t errcap) {
    if (!rt) { if (err && errcap) snprintf(err, errcap, "null db"); return -1; }
    if (dl_txn_begin(rt) != 0) {
        if (err && errcap) snprintf(err, errcap, "txn_begin failed");
        return -1;
    }
    probe_process(rt, root);
    probe_fs(rt);
    probe_file(rt, root);
    probe_net(rt, root);
    probe_kernel(rt, root);
    probe_env(rt);
    if (dl_txn_commit(rt) != 0) {
        dl_txn_rollback(rt);
        if (err && errcap) snprintf(err, errcap, "txn_commit failed");
        return -1;
    }
    return 0;
}
