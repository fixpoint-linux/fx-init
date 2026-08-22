/* tests/fixtures/fakesvc_daemon/fakesvc_daemon.c — a daemonizing-service fixture
 * for the genuine-PID1 boot harness (tests/fxinit_pid1.sh).
 *
 * Real services often double-fork a daemon grandchild: the direct child that
 * fx-init spawns (the tracked sv->pid) forks an intermediate, which forks the
 * daemon, and the intermediate exits.  The daemon grandchild is then ORPHANED
 * and reparented to the nearest init.  This fixture reproduces that so the
 * harness can verify fx-init (as PID1 / child subreaper) adopts the orphan and
 * reaps it when it exits (no zombie).
 *
 * argv:
 *   fakesvc_daemon pid1
 *       Long-running: print the comm of the process holding PID 1 in this
 *       namespace ("proc1comm=<comm>").  Must be "fx-init" when fx-init is the
 *       genuine PID1; anything else (e.g. "bwrap") proves it is not.
 *   fakesvc_daemon daemon <hold> <secs> <pidfile> <reportfile>
 *       Direct child forks intermediate -> forks daemon grandchild, then:
 *         - the direct child (tracked service) stays alive `hold` seconds, so
 *           the boot-ok grace (which requires every service STARTED) can elapse
 *           before it exits — otherwise a daemonizing service's early exit would
 *           be (correctly) pinned as a boot start-failure;
 *         - the grandchild records "<pid> <ppid>" to <pidfile> (the ppid proves
 *           WHICH process adopted it — must be 1, i.e. fx-init/PID1), forks a
 *           watchdog, sleeps `secs`, then exits (becoming the zombie fx-init
 *           must reap);
 *         - the watchdog outlives it (secs+3s), then inspects
 *           /proc/<grandchild-pid>/stat and writes the verdict to <reportfile>:
 *           "reaped"  -> /proc entry gone: fx-init reaped it (no zombie);
 *           "zombie"  -> state 'Z' still present: fx-init did NOT reap (leak);
 *           "running" / "unknown" -> other.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* read the grandchild's PPid from /proc/self/stat (reflects post-orphan
 * adoption, since the intermediate parent has already exited).  Returns -1 on
 * any parse failure. */
static long self_ppid(void) {
    FILE *f = fopen("/proc/self/stat", "r");
    if (!f) return -1;
    char s[512];
    long ppid = -1;
    if (fgets(s, (int)sizeof s, f)) {
        char *rp = strrchr(s, ')');            /* skip "pid (comm)" */
        if (rp) {
            char st;
            if (sscanf(rp + 1, " %c %ld", &st, &ppid) != 2) ppid = -1;
        }
    }
    fclose(f);
    return ppid;
}

static int mode_pid1(void) {
    char comm[64] = "?";
    FILE *f = fopen("/proc/1/comm", "r");
    if (f) {
        char b[64];
        if (fgets(b, (int)sizeof b, f)) {
            b[strcspn(b, "\n")] = '\0';
            snprintf(comm, sizeof comm, "%s", b);
        }
        fclose(f);
    }
    printf("proc1comm=%s\n", comm);
    fflush(stdout);
    for (;;) pause();          /* long-running service so boot stays STARTED */
    return 0;                  /* unreachable */
}

static int mode_daemon(char *hold_s, char *secs_s, char *pidfile, char *reportfile) {
    long hold = hold_s ? strtol(hold_s, NULL, 10) : 7;
    long secs = secs_s ? strtol(secs_s, NULL, 10) : 8;
    if (hold < 1) hold = 1;
    if (secs < 1) secs = 1;

    /* fork #1 -> intermediate.  The direct child (the tracked service) holds
     * `hold` seconds so the boot-ok grace can pass before it exits. */
    pid_t c1 = fork();
    if (c1 < 0) { perror("fork1"); return 1; }
    if (c1 > 0) { sleep((unsigned)hold); _exit(0); }

    /* intermediate: setsid, fork #2 -> daemon grandchild */
    setsid();
    pid_t c2 = fork();
    if (c2 < 0) { perror("fork2"); return 1; }
    if (c2 > 0) { _exit(0); }   /* intermediate exits now: c2 becomes an orphan */

    /* daemon grandchild (c2) — orphaned, reparented to fx-init (PID1/subreaper) */
    setsid();
    {
        /* detach stdio so we hold no fx-init output pipe and never SIGPIPE on
         * it after the tracked direct child has exited. */
        int dn = open("/dev/null", O_RDWR);
        if (dn >= 0) { dup2(dn, 0); dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); }
    }
    pid_t me = getpid();

    /* record pid + adopted PPid — the KEY adoption evidence for the harness */
    if (pidfile) {
        FILE *pf = fopen(pidfile, "w");
        if (pf) {
            fprintf(pf, "%ld %ld\n", (long)me, self_ppid());
            fclose(pf);
        }
    }

    /* watchdog: outlive `me`, then verify fx-init reaped me (no zombie) */
    pid_t wd = fork();
    if (wd == 0) {
        sleep((unsigned)(secs + 3));
        char path[64];
        snprintf(path, sizeof path, "/proc/%ld/stat", (long)me);
        FILE *g = fopen(path, "r");
        FILE *rf = reportfile ? fopen(reportfile, "w") : NULL;
        const char *verdict;
        if (!g) {
            verdict = "reaped";                       /* /proc entry gone */
        } else {
            char s[512];
            char st = '?';
            if (fgets(s, (int)sizeof s, g)) {
                char *rp = strrchr(s, ')');
                if (rp && sscanf(rp + 1, " %c", &st) != 1) st = '?';
            }
            fclose(g);
            if (st == 'Z') verdict = "zombie";
            else if (st == 'R' || st == 'S' || st == 'D') verdict = "running";
            else verdict = "unknown";
        }
        if (rf) { fprintf(rf, "%s\n", verdict); fclose(rf); }
        _exit(0);
    }

    /* grandchild sleeps then exits, becoming the zombie fx-init must reap */
    sleep((unsigned)secs);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: fakesvc_daemon <pid1|daemon <hold> <secs> <pidfile> <reportfile>>\n"); return 2; }
    if (!strcmp(argv[1], "pid1"))   return mode_pid1();
    if (!strcmp(argv[1], "daemon")) return mode_daemon(argc > 2 ? argv[2] : NULL,
                                                       argc > 3 ? argv[3] : NULL,
                                                       argc > 4 ? argv[4] : NULL,
                                                       argc > 5 ? argv[5] : NULL);
    fprintf(stderr, "fakesvc_daemon: unknown mode %s\n", argv[1]);
    return 2;
}
