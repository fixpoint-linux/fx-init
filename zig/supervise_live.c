/* supervise_live.c — live fx_sock_ready differential: drives the C
 * fx_sock_ready (src/fx_supervise.c) and the Zig fx_sock_ready
 * (zig/src/supervise.zig, linked from its object export) against the SAME
 * real listening AF_INET 127.0.0.1 + AF_UNIX sockets and asserts they
 * return the SAME 1/0 in every state — listening, after close (TCP) /
 * close+unlink (UNIX), NULL/empty/nonexistent args.
 *
 * The Zig fx_sock_ready is reached through a tiny wrapper object
 * (zig/zig-out/supervise_extern.o) exposing `zig_fx_sock_ready` — built by
 * supervise_diff.sh BEFORE this program compiles.
 *
 * Sandboxed (rattan) runs may block socket() entirely (EPERM): like
 * tests/supervise_test.c, the listening-socket assertions are gated on a
 * socket() probe and the pure-input cases always run.
 */
#include "fx_supervise.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <stdint.h>

/* the Zig port, exposed via the wrapper object */
extern int zig_fx_sock_ready(int tcp, const char *arg);

static int fails = 0;

static void same(const char *what, int c, int z) {
    if (c == z) {
        printf("    OK %s: c=%d zig=%d\n", what, c, z);
    } else {
        printf("    FAIL %s: c=%d zig=%d\n", what, c, z);
        fails++;
    }
}

static int listen_tcp(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001u); a.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    if (listen(fd, 4) != 0) { close(fd); return -1; }
    socklen_t l = sizeof a;
    if (getsockname(fd, (struct sockaddr *)&a, &l) != 0) { close(fd); return -1; }
    *port_out = ntohs(a.sin_port);
    return fd;
}

/* listen on a SPECIFIC port (65535): makes the strtoul overflow cases
 * discriminating — those all map to port 65535 (see below), so with this
 * listener up both sides must return 1; a fix that probed port 1 instead
 * would return 0 and FAIL.  -1 if bind fails (port taken / no sockets). */
static int listen_tcp_port(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001u); a.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    /* backlog 128: each 65535-probing call leaves a COMPLETED connection in
     * the accept queue (we never accept it), and both sides probe this port
     * repeatedly — with the default 4 the queue fills and later probes
     * SYN-drop+timeout, breaking agreement on queue position, not on port
     * math (observed: C 5th queued connect -> 1, Zig 6th -> 0). */
    if (listen(fd, 128) != 0) { close(fd); return -1; }
    return fd;
}

static int listen_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof a.sun_path - 1);
    unlink(path);  /* stale socket */
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    if (listen(fd, 4) != 0) { close(fd); unlink(path); return -1; }
    return fd;
}

int main(void) {
    /* sandbox probe: skip the listening-socket assertions when socket() is
     * blocked (the pure-input cases below run everywhere) */
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    int have_sockets = (probe >= 0);
    if (probe >= 0) close(probe);
    if (!have_sockets)
        printf("  (skip: socket() blocked in this sandbox; "
               "listening-socket assertions run on the host)\n");

    /* pure-input cases (no listener needed; agree everywhere) */
    same("tcp NULL arg", fx_sock_ready(1, NULL), zig_fx_sock_ready(1, NULL));
    same("tcp empty arg", fx_sock_ready(1, ""), zig_fx_sock_ready(1, ""));
    same("unix NULL arg", fx_sock_ready(0, NULL), zig_fx_sock_ready(0, NULL));
    same("unix nonexistent path",
         fx_sock_ready(0, "/run/fx/does-not-exist-xyz"),
         zig_fx_sock_ready(0, "/run/fx/does-not-exist-xyz"));

    /* WEIRD-ARG agreement (review2): pins the (uint16_t)strtoul port-cast
     * fidelity.  Both sides compute the same port, so they agree regardless
     * of listener state.  With the 65535 listener up, the overflow cases
     * become POSITIVE probes: glibc strtoul maps -1 (magnitude 1, negated
     * wrap), positive 21-digit overflow (ERANGE -> ULONG_MAX) and the
     * negative-overflow boundary -18446744073709551617 (ERANGE -> ULONG_MAX
     * and the sign negation is SKIPPED) all to port 65535 after the uint16_t
     * cast — the negation-skip is exactly what fix-2 pins; a port that
     * negated instead would hit port 1 and return 0 here. */
    int bfd = have_sockets ? listen_tcp_port(65535) : -1;
    same("tcp 21-digit overflow",
         fx_sock_ready(1, "999999999999999999999"),
         zig_fx_sock_ready(1, "999999999999999999999"));
    same("tcp -1", fx_sock_ready(1, "-1"), zig_fx_sock_ready(1, "-1"));
    same("tcp 65536 (casts to port 0)",
         fx_sock_ready(1, "65536"), zig_fx_sock_ready(1, "65536"));
    same("tcp trailing junk", fx_sock_ready(1, "80junk"), zig_fx_sock_ready(1, "80junk"));
    same("tcp no digits", fx_sock_ready(1, "notaport"), zig_fx_sock_ready(1, "notaport"));
    same("tcp plus prefix", fx_sock_ready(1, "+80"), zig_fx_sock_ready(1, "+80"));
    same("tcp leading space", fx_sock_ready(1, " 80"), zig_fx_sock_ready(1, " 80"));
    same("tcp negative-overflow boundary -18446744073709551617",
         fx_sock_ready(1, "-18446744073709551617"),
         zig_fx_sock_ready(1, "-18446744073709551617"));
    if (bfd >= 0) close(bfd);
    else
        printf("  (note: 65535 not bindable; overflow cases assert agreement only)\n");

    /* unix arg longer than sun_path-1 (107): both sides truncate to 107
     * bytes over a zeroed sockaddr (strncpy / @min len), so they agree on
     * the same (here nonexistent) path.  When sockets work, ALSO pin the
     * truncation length for real: a listener at an exactly-107-char path
     * must be REACHED through the >107-char arg by BOTH sides — a
     * truncation off-by-one would land one byte short (ENOENT) and fail
     * exactly one side. */
    {
        char base[108];
        int blen = snprintf(base, sizeof base, "/tmp/fxlong-%d", (int)getpid());
        while (blen < 107) base[blen++] = 'a';
        base[blen] = '\0';   /* exactly 107 chars + NUL */
        char longarg[224];
        int ll = snprintf(longarg, sizeof longarg, "%s", base);
        while (ll < 207) longarg[ll++] = 'b';
        longarg[ll] = '\0';  /* 207 chars: well past the 107-byte window */
        same("unix >107-char path (no listener)",
             fx_sock_ready(0, longarg), zig_fx_sock_ready(0, longarg));
        if (have_sockets) {
            int lufd = listen_unix(base);
            if (lufd >= 0) {
                same("unix >107-char arg reaches 107-char listener",
                     fx_sock_ready(0, longarg), zig_fx_sock_ready(0, longarg));
                close(lufd); unlink(base);
            }
        }
    }

    /* TCP: ready while listening, same 1/0 for both. */
    uint16_t port = 0; int lfd = have_sockets ? listen_tcp(&port) : -1;
    if (lfd >= 0) {
        char ps[16]; snprintf(ps, sizeof ps, "%u", (unsigned)port);
        same("tcp listening", fx_sock_ready(1, ps), zig_fx_sock_ready(1, ps));
        close(lfd);
        /* after close: ECONNREFUSED on loopback — assert AGREEMENT, not a
         * specific value (a racing re-bind could flip the bit for both). */
        same("tcp after close",
             fx_sock_ready(1, ps), zig_fx_sock_ready(1, ps));
    }

    /* AF_UNIX: ready while listening, 0 for both after close+unlink. */
    char upath[128]; snprintf(upath, sizeof upath, "/tmp/fxsock-zig-%d.sock", (int)getpid());
    int ufd = have_sockets ? listen_unix(upath) : -1;
    if (ufd >= 0) {
        same("unix listening", fx_sock_ready(0, upath), zig_fx_sock_ready(0, upath));
        close(ufd); unlink(upath);
        same("unix after close+unlink",
             fx_sock_ready(0, upath), zig_fx_sock_ready(0, upath));
    }

    if (fails) { printf("supervise_live: %d FAIL\n", fails); return 1; }
    printf("supervise_live: PASS\n");
    return 0;
}
