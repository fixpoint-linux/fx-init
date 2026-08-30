/* fxctl_live.c — LIVE regression driver for the fxctl client against a
 * fake fx-init AF_UNIX server kept in-process (fork: child = client,
 * parent = server), one listening socket per case.
 *
 * Modes:
 *   fxctl_live pin   <client-bin> <golden-dir>
 *       Run the client on every case and WRITE its stdout/stderr/rc to
 *       <golden-dir>/<slug>.{out,err,rc}.  Used ONCE pre-deletion with the
 *       REAL C client (src/fxctl.c) to pin the client contract; the goldens
 *       are the C client's verified behavior (the request-line half of the
 *       old differential plus the 13-case live diff were byte-green).
 *   fxctl_live check <client-bin> <golden-dir>
 *       Run the client on every case and byte-compare stdout/stderr/rc
 *       against the goldens (default fxctl_diff.sh mode).
 *
 * Modes pin the full client contract end-to-end:
 *   ECHO           — request line echoed back as a data line + OK: pins the
 *                    request BYTES of the real binary (quoting + 4096 cap)
 *   DATA3          — three data lines then OK
 *   ERR/_TAB/_BARE — the three ERR spellings (msg to stderr, rc 1)
 *   ERR_SUFFIX     — "ERRSUFFIX" is a DATA line, then OK (rc 0)
 *   ERR_AFTER_DATA — data lines then ERR (both streams populated, rc 1)
 *   CLOSE          — accept + read the request, close with no reply: the
 *                    "no response (timeout/disconnect)" path (rc 1)
 *   NOT_RUNNING    — FX_SOCKET points at an absent path: "fx-init not
 *                    running" (rc 1); needs no listener (sandbox-safe)
 *   NOARGS         — usage on stderr, rc 2 (before any socket work)
 *
 * Sandboxed (rattan) runs may block socket(): the server cases are then
 * skipped, NOT_RUNNING + NOARGS still run (supervise_live.c probe pattern);
 * in check mode skipped cases are simply not compared (their goldens stay
 * from the host run).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>

enum {
    M_ECHO, M_DATA3, M_ERR, M_ERR_TAB, M_ERR_BARE, M_ERR_SUFFIX,
    M_ERR_AFTER_DATA, M_CLOSE, M_NOT_RUNNING
};

static const char *g_bin;
static const char *g_golden;
static char g_dir[128];
static int fails = 0;

static void xput(int fd, const char *s, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

static int listen_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    unlink(path); /* stale socket */
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    if (listen(fd, 8) != 0) { close(fd); unlink(path); return -1; }
    return fd;
}

/* server side of one case: accept, read the request line, respond per mode */
static void serve(int lfd, int mode) {
    int c = accept(lfd, NULL, NULL);
    if (c < 0) return;
    char req[65536];
    size_t n = 0;
    while (n < sizeof req) {
        char ch;
        ssize_t r = read(c, &ch, 1);
        if (r <= 0) break;
        req[n++] = ch;
        if (ch == '\n') break;
    }
    switch (mode) {
    case M_ECHO:
        if (n > 0) xput(c, req, n); /* echo the (capped) request line back */
        xput(c, "OK\n", 3);
        break;
    case M_DATA3: xput(c, "alpha\nbeta\ngamma\nOK\n", 20); break;
    case M_ERR: xput(c, "ERR no such thing\n", 18); break;
    case M_ERR_TAB: xput(c, "ERR\ttabby\n", 10); break;
    case M_ERR_BARE: xput(c, "ERR\n", 4); break;
    case M_ERR_SUFFIX: xput(c, "ERRSUFFIX is data\nOK\n", 21); break;
    case M_ERR_AFTER_DATA: xput(c, "one\ntwo\nERR late\n", 17); break;
    case M_CLOSE:
    default: break; /* no reply at all */
    }
    close(c);
}

/* Run the client against the case's server; stdout/stderr go to
 * <dir>/c.{out,err}.  Returns the exit status (128+sig if killed), or -1
 * if the case could not be set up. */
static int run_one(int mode, char **args, int nargs) {
    char sp[256], absent[256];
    const char *sockpath = NULL;
    int lfd = -1;
    snprintf(absent, sizeof absent, "%s/absent.sock", g_dir);
    if (mode != M_NOT_RUNNING) {
        snprintf(sp, sizeof sp, "%s/ctl.sock", g_dir);
        lfd = listen_unix(sp);
        if (lfd < 0) return -1;
        sockpath = sp;
    } else {
        sockpath = absent; /* existing dir, missing file -> ENOENT */
    }

    char outp[256], errp[256];
    snprintf(outp, sizeof outp, "%s/c.out", g_dir);
    snprintf(errp, sizeof errp, "%s/c.err", g_dir);

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(2); }
    if (pid == 0) {
        int o = open(outp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        int e = open(errp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (o >= 0) dup2(o, 1);
        if (e >= 0) dup2(e, 2);
        setenv("FX_SOCKET", sockpath, 1);
        char *argv[16];
        int k = 0;
        argv[k++] = (char *)g_bin;
        for (int i = 0; i < nargs && k < 15; i++) argv[k++] = args[i];
        argv[k] = NULL;
        execv(argv[0], argv);
        _exit(127);
    }
    if (lfd >= 0) {
        serve(lfd, mode);
        close(lfd);
        unlink(sp);
    }
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) { perror("waitpid"); exit(2); }
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return 128 + WTERMSIG(st);
}

static int file_eq(const char *a, const char *b) {
    FILE *fa = fopen(a, "rb"), *fb = fopen(b, "rb");
    if (!fa || !fb) {
        if (fa) fclose(fa);
        if (fb) fclose(fb);
        return 0;
    }
    int eq = 1, ca, cb;
    do {
        ca = fgetc(fa);
        cb = fgetc(fb);
        if (ca != cb) { eq = 0; break; }
    } while (ca != EOF);
    fclose(fa);
    fclose(fb);
    return eq;
}

static void show(const char *tag, const char *path) {
    FILE *f = fopen(path, "rb");
    printf("    %s: \"", tag);
    if (f) {
        int ch;
        while ((ch = fgetc(f)) != EOF) {
            if (ch == '\n') printf("\\n");
            else if (ch == '\t') printf("\\t");
            else if (ch < 32 || ch > 126) printf("\\x%02x", (unsigned)ch);
            else putchar(ch);
        }
        fclose(f);
    }
    printf("\"\n");
}

/* Rewrite path in place, replacing occurrences of the mkdtemp dir with
 * "GDIR" — the socket path leaks into client stderr (e.g. "not running")
 * and the dir name is random per run, so both pinning and checking must
 * normalize it. */
static void normalize_file(char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return; }
    char *buf = malloc((size_t)n + 1);
    if (!buf) { fclose(f); return; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    char *p = buf, *q = buf;
    while ((size_t)(p - buf) < got) {
        char *hit = strstr(p, g_dir);
        if (!hit || hit >= buf + got) break;
        memmove(q, p, (size_t)(hit - p));
        q += hit - p;
        memcpy(q, "GDIR", 4);
        q += 4;
        p = hit + strlen(g_dir);
    }
    memmove(q, p, got - (size_t)(p - buf));
    q += got - (size_t)(p - buf);
    f = fopen(path, "wb");
    if (f) { fwrite(buf, 1, (size_t)(q - buf), f); fclose(f); }
    free(buf);
}

static void copy_file(const char *from, const char *to) {
    FILE *fi = fopen(from, "rb"), *fo = fopen(to, "wb");
    if (!fi || !fo) { fprintf(stderr, "copy %s -> %s failed\n", from, to); exit(2); }
    int ch;
    while ((ch = fgetc(fi)) != EOF) fputc(ch, fo);
    fclose(fi);
    fclose(fo);
}

static void run_case(int pin, const char *slug, const char *name, int mode,
                     int nargs, ...) {
    char *args[16];
    va_list ap;
    va_start(ap, nargs);
    for (int i = 0; i < nargs; i++) args[i] = va_arg(ap, char *);
    va_end(ap);

    int rc = run_one(mode, args, nargs);
    if (rc < 0) {
        printf("  (skip %s: listen failed)\n", name);
        return;
    }
    char co[256], ce[256];
    snprintf(co, sizeof co, "%s/c.out", g_dir);
    snprintf(ce, sizeof ce, "%s/c.err", g_dir);
    normalize_file(co);
    normalize_file(ce);

    char go[256], ge[256], gr[256];
    snprintf(go, sizeof go, "%s/%s.out", g_golden, slug);
    snprintf(ge, sizeof ge, "%s/%s.err", g_golden, slug);
    snprintf(gr, sizeof gr, "%s/%s.rc", g_golden, slug);

    if (pin) {
        copy_file(co, go);
        copy_file(ce, ge);
        FILE *f = fopen(gr, "wb");
        if (!f) { fprintf(stderr, "cannot write %s\n", gr); exit(2); }
        fprintf(f, "%d\n", rc);
        fclose(f);
        printf("    PIN %s: rc=%d\n", name, rc);
        return;
    }

    char expected_rc[16], actual_rc[16];
    snprintf(actual_rc, sizeof actual_rc, "%d\n", rc);
    int have = 1;
    FILE *f = fopen(gr, "rb");
    if (!f) have = 0;
    else { fgets(expected_rc, sizeof expected_rc, f); fclose(f); }
    int oeq = file_eq(go, co), eeq = file_eq(ge, ce);
    if (have && oeq && eeq && strcmp(expected_rc, actual_rc) == 0) {
        printf("    OK %s: rc=%d\n", name, rc);
    } else {
        printf("    FAIL %s: rc=%d (golden %s), stdout_eq=%d stderr_eq=%d\n",
               name, rc, have ? expected_rc : "MISSING", oeq, eeq);
        if (!oeq) { show("golden.out", go); show("actual.out", co); }
        if (!eeq) { show("golden.err", ge); show("actual.err", ce); }
        fails++;
    }
}

int main(int argc, char **argv) {
    int pin;
    if (argc == 4 && (strcmp(argv[1], "pin") == 0 || strcmp(argv[1], "check") == 0)) {
        pin = (strcmp(argv[1], "pin") == 0);
    } else {
        fprintf(stderr, "usage: fxctl_live pin|check <client-bin> <golden-dir>\n");
        return 2;
    }
    g_bin = argv[2];
    g_golden = argv[3];
    snprintf(g_dir, sizeof g_dir, "/tmp/fxctl_live.XXXXXX");
    if (!mkdtemp(g_dir)) { perror("mkdtemp"); return 2; }
    signal(SIGALRM, SIG_DFL);
    alarm(120); /* a hung client/accept must not hang the harness */

    /* sandbox probe: socket() blocked -> skip the server cases */
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    int have_sockets = (probe >= 0);
    if (probe >= 0) close(probe);
    if (!have_sockets)
        printf("  (skip: socket() blocked in this sandbox; server cases run on the host)\n");

    if (have_sockets) {
        run_case(pin, "echo-status", "echo: status", M_ECHO, 1, "status");
        run_case(pin, "echo-quoting", "echo: quoting (spaces/empty/quotes)",
                 M_ECHO, 5, "q", "users", "a b", "", "c\"d");
        run_case(pin, "echo-tab-arg", "echo: tab arg", M_ECHO, 2, "search", "x\ty");
        /* one 5000-char arg: the request is capped at 4095 by the CLIENT,
         * so the echoed data line pins the cap on the real binary */
        static char longarg[5001];
        memset(longarg, 'x', 5000);
        run_case(pin, "echo-5000-cap", "echo: 5000-char arg (4096 cap)",
                 M_ECHO, 3, "q", "users", longarg);
        run_case(pin, "data3-ok", "data3 + OK", M_DATA3, 1, "status");
        run_case(pin, "err-msg", "ERR msg", M_ERR, 1, "bogus");
        run_case(pin, "err-tab", "ERR tab", M_ERR_TAB, 1, "bogus");
        run_case(pin, "err-bare", "ERR bare", M_ERR_BARE, 1, "bogus");
        run_case(pin, "err-suffix-data", "ERRSUFFIX is a data line", M_ERR_SUFFIX, 1, "bogus");
        run_case(pin, "data-then-err", "data then ERR", M_ERR_AFTER_DATA, 1, "grep", "oops");
        run_case(pin, "close-no-reply", "close without reply (no response)", M_CLOSE, 1, "status");
    }
    /* always run: no listener needed */
    run_case(pin, "not-running", "not running", M_NOT_RUNNING, 1, "status");
    run_case(pin, "no-args-usage", "no args (usage)", M_NOT_RUNNING, 0);

    /* leave no socket file behind; keep the dir for post-mortem only if failing */
    char sp[256];
    snprintf(sp, sizeof sp, "%s/ctl.sock", g_dir);
    unlink(sp);
    snprintf(sp, sizeof sp, "%s/absent.sock", g_dir);
    unlink(sp);
    if (!fails) rmdir(g_dir);

    if (fails) { printf("fxctl_live: %d FAIL (dir %s)\n", fails, g_dir); return 1; }
    printf("fxctl_live: PASS\n");
    return 0;
}
