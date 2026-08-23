/* fxctl.c — (U-D) the fx-init control/query client.
 *
 * A pure POSIX client that links NOTHING from vendor.  It maps subcommands
 * to a single request line over $FX_RUN/control.sock (default /run/fx) and
 * streams the response lines to stdout, terminating on `OK` (exit 0) or
 * `ERR <msg>` (exit 1).  fxctl never opens any datalog DB directly — all
 * reads go through the socket (the actor/sole-writer model: dl_open takes a
 * process-lifetime exclusive lock, so direct access would block fx-init).
 *
 * Subcommands:
 *   status                       composed boot/generation/service snapshot
 *   q <rel> [v1 v2..]            runtime relation query (all or bound prefix)
 *   start|stop|restart <svc>     service control
 *   probe                        refresh OS probe relations now
 *   activate <config-path>       init runs fxstore activate; prints new ver
 *   rollback <version>           roll-forward to a known-good version
 *   shutdown                     orderly SIGTERM-style shutdown
 *   grep <regex>                 log regex search
 *   search <term> [term..]       log full-text AND search
 *
 * Env: FX_RUN (default /run/fx) locates control.sock; FX_SOCKET overrides the
 * full path.  Socket absent -> "fxctl: fx-init not running (<path>)" exit 1.
 * Connect timeout 5s via SO_RCVTIMEO.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <errno.h>

#define LINE_MAX_REQ 4096

static const char *sock_path(void) {
    const char *s = getenv("FX_SOCKET");
    if (s && s[0]) return s;
    const char *run = getenv("FX_RUN");
    if (!run || !run[0]) run = "/run/fx";
    static char buf[512];
    snprintf(buf, sizeof buf, "%s/control.sock", run);
    return buf;
}

static int connect_sock(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct timeval to = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &to, sizeof to);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    size_t pl = strlen(path);
    if (pl >= sizeof a.sun_path) pl = sizeof a.sun_path - 1;
    memcpy(a.sun_path, path, pl);
    a.sun_path[pl] = '\0';
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* send one newline-terminated request line */
static int send_line(int fd, const char *line) {
    size_t n = strlen(line);
    if (n > LINE_MAX_REQ) n = LINE_MAX_REQ;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, line + off, n - off);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        off += (size_t)w;
    }
    char nl = '\n';
    ssize_t w;
    do { w = write(fd, &nl, 1); } while (w < 0 && errno == EINTR);
    return w < 0 ? -1 : 0;
}

/* read response lines until OK / ERR; stream data lines to stdout.  Returns
 * 0 on OK, 1 on ERR, -1 on transport error. */
static int read_response(int fd) {
    FILE *r = fdopen(fd, "r");
    if (!r) return -1;
    char line[8192];
    int rc = -1;
    while (fgets(line, sizeof line, r)) {
        size_t L = strlen(line);
        int had_nl = (L > 0 && line[L - 1] == '\n');
        if (had_nl) line[L - 1] = '\0';
        if (strcmp(line, "OK") == 0) { rc = 0; break; }
        if (strncmp(line, "ERR", 3) == 0 &&
            (line[3] == '\0' || line[3] == ' ' || line[3] == '\t')) {
            fprintf(stderr, "%s\n", line);
            rc = 1;
            break;
        }
        /* data line */
        puts(line);
    }
    fclose(r);  /* also closes fd */
    return rc;
}

static void usage(FILE *o) {
    fprintf(o,
        "usage: fxctl <subcommand> [args]\n"
        "  status | q <rel> [vals..] | start|stop|restart <svc> | probe\n"
        "  activate <config> | rollback <ver> | shutdown\n"
        "  grep <regex> | search <term> [term..]\n"
        "env: FX_RUN (default /run/fx), FX_SOCKET (override control.sock path)\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(stderr); return 2; }

    /* build the request line from the subcommand + args */
    char req[LINE_MAX_REQ];
    size_t off = 0;
    for (int i = 1; i < argc; i++) {
        if (i > 1) { if (off < sizeof req - 1) req[off++] = ' '; }
        const char *a = argv[i];
        size_t al = strlen(a);
        /* quote if it contains spaces or is empty */
        int quote = (al == 0 || strchr(a, ' ') || strchr(a, '\t'));
        if (quote && off < sizeof req - 1) req[off++] = '"';
        for (size_t j = 0; j < al; j++) {
            if (off < sizeof req - 1) req[off++] = a[j];
        }
        if (quote && off < sizeof req - 1) req[off++] = '"';
    }
    req[off] = '\0';

    const char *path = sock_path();
    int fd = connect_sock(path);
    if (fd < 0) {
        if (errno == ENOENT || errno == ECONNREFUSED)
            fprintf(stderr, "fxctl: fx-init not running (%s)\n", path);
        else if (errno == EAFNOSUPPORT || errno == ENOTSUP ||
                 errno == EPROTONOSUPPORT)
            fprintf(stderr,
                "fxctl: cannot connect to %s: Unix-domain sockets are not "
                "supported on this platform (browser wasm) — fx-init's PID1 "
                "control.sock is not running here\n",
                path);
        else
            fprintf(stderr, "fxctl: connect %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (send_line(fd, req) < 0) {
        fprintf(stderr, "fxctl: send failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    int rc = read_response(fd);
    if (rc < 0) {
        fprintf(stderr, "fxctl: no response (timeout/disconnect)\n");
        return 1;
    }
    return rc;
}
