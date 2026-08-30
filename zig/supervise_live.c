/* supervise_live.c — live fx_sock_ready regression driver for the Zig port
 * (zig/src/supervise.zig, linked from its object export).
 *
 * Formerly a C-vs-Zig differential (the C fx_sock_ready lived in
 * src/fx_supervise.c, now removed).  It now drives ONLY the Zig
 * fx_sock_ready against real AF_INET 127.0.0.1 + AF_UNIX sockets and
 * asserts the ABSOLUTE 1/0 contract — every surviving expectation is a
 * state that is deterministic by construction:
 *
 *   - pure-input cases (NULL/empty/nonexistent)          -> 0
 *   - port-0 resolvers ("65536" truncation, "notaport")  -> 0
 *   - with the harness's OWN 65535 listener held: the strtoul-overflow
 *     resolvers ("999...", "-1", "-18446...617") all land on port 65535
 *     (uint16_t cast; ERANGE->ULONG_MAX with the negation skip) and MUST
 *     connect                                           -> 1
 *   - unix listening -> 1; after close+unlink             -> 0
 *   - a >107-char unix arg must reach an exactly-107-char listener
 *     (truncation length)                                -> 1
 *   - tcp listening (ephemeral port)                      -> 1
 *
 * Dropped relative to the differential era, per the reasoning recorded
 * when the C oracle was removed:
 *   - "tcp after close": a racing re-bind can flip the bit (was an
 *     agreement-only check); now an unconstrained smoke call.
 *   - "80junk"/"+80"/" 80": resolve to port 80, so the result depends on
 *     unrelated host state; the port-math fidelity they pinned is already
 *     covered by the 65535-resolver + port-0 cases above.
 *
 * The Zig fx_sock_ready is reached through a tiny wrapper object
 * (zig/zig-out/supervise_extern.o) exposing `zig_fx_sock_ready` — built by
 * supervise_diff.sh BEFORE this program compiles.
 *
 * Sandboxed (rattan) runs may block socket() entirely (EPERM): the
 * listening-socket assertions are gated on a socket() probe and the
 * pure-input cases always run.
 */
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

static int checks = 0, fails = 0;

static void expect(const char *what, int got, int want) {
    checks++;
    if (got == want) {
        printf("    OK %s: %d\n", what, got);
    } else {
        printf("    FAIL %s: got %d, want %d\n", what, got, want);
        fails++;
    }
}

/* unconstrained run: must return without hanging/crashing; value printed
 * only (kept as a smoke call where the old differential was
 * agreement-only because the value is environment-dependent) */
static void smoke(const char *what, int got) {
    checks++;
    printf("    OK %s: (unconstrained) %d\n", what, got);
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
 * POSITIVE probes — those all map to port 65535 after the (uint16_t)
 * cast (glibc strtoul: "-1" magnitude-wrap, ERANGE->ULONG_MAX with the
 * negation skip), so with this listener up they must all return 1; a
 * port-math regression (e.g. negating when it should skip) would hit
 * port 1 and return 0 instead.  -1 if bind fails (port taken / no
 * sockets): the overflow cases are then skipped (see caller). */
static int listen_tcp_port(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001u); a.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    /* backlog 128: each probing call leaves a COMPLETED connection in the
     * accept queue (we never accept it) and we probe this port repeatedly —
     * with the default 4 the queue fills and later probes
     * SYN-drop+timeout, flipping results on queue position, not port math
     * (observed during the C-vs-Zig era). */
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

    /* pure-input cases (no listener needed; deterministic everywhere) */
    expect("tcp NULL arg", zig_fx_sock_ready(1, NULL), 0);
    expect("tcp empty arg", zig_fx_sock_ready(1, ""), 0);
    expect("unix NULL arg", zig_fx_sock_ready(0, NULL), 0);
    expect("unix nonexistent path",
           zig_fx_sock_ready(0, "/run/fx/does-not-exist-xyz"), 0);

    /* port-0 resolvers: (uint16_t)65536 == 0, strtoul("notaport") == 0 —
     * connect(2) to port 0 never succeeds -> deterministic 0 */
    expect("tcp 65536 (casts to port 0)", zig_fx_sock_ready(1, "65536"), 0);
    expect("tcp no digits", zig_fx_sock_ready(1, "notaport"), 0);

    /* strtoul-overflow port math, pinned POSITIVE against our own 65535
     * listener (deterministic while the listener is held) */
    int bfd = have_sockets ? listen_tcp_port(65535) : -1;
    if (bfd >= 0) {
        expect("tcp 21-digit overflow (-> 65535)",
               zig_fx_sock_ready(1, "999999999999999999999"), 1);
        expect("tcp -1 (magnitude wrap -> 65535)", zig_fx_sock_ready(1, "-1"), 1);
        expect("tcp negative-overflow boundary -18446744073709551617 (negation skip -> 65535)",
               zig_fx_sock_ready(1, "-18446744073709551617"), 1);
        close(bfd);
    } else {
        printf("  (skip: 65535 not bindable; overflow resolvers unpinned this run)\n");
    }

    /* unix arg longer than sun_path-1 (107): truncated to 107 bytes over a
     * zeroed sockaddr (@min len) — nonexistent without a listener -> 0;
     * with a listener at an exactly-107-char path the >107-char arg must
     * still REACH it (a truncation off-by-one would land one byte short,
     * ENOENT, 0). */
    {
        char base[108];
        int blen = snprintf(base, sizeof base, "/tmp/fxlong-%d", (int)getpid());
        while (blen < 107) base[blen++] = 'a';
        base[blen] = '\0';   /* exactly 107 chars + NUL */
        char longarg[224];
        int ll = snprintf(longarg, sizeof longarg, "%s", base);
        while (ll < 207) longarg[ll++] = 'b';
        longarg[ll] = '\0';  /* 207 chars: well past the 107-byte window */
        expect("unix >107-char path (no listener)",
               zig_fx_sock_ready(0, longarg), 0);
        if (have_sockets) {
            int lufd = listen_unix(base);
            if (lufd >= 0) {
                expect("unix >107-char arg reaches 107-char listener",
                       zig_fx_sock_ready(0, longarg), 1);
                close(lufd); unlink(base);
            } else {
                printf("  (skip: 107-char unix listener not bindable)\n");
            }
        }
    }

    /* TCP: ready while listening (ephemeral port).  After close the value
     * is racy (a re-bind can flip it) — smoke call only. */
    uint16_t port = 0; int lfd = have_sockets ? listen_tcp(&port) : -1;
    if (lfd >= 0) {
        char ps[16]; snprintf(ps, sizeof ps, "%u", (unsigned)port);
        expect("tcp listening", zig_fx_sock_ready(1, ps), 1);
        close(lfd);
        smoke("tcp after close (racy)", zig_fx_sock_ready(1, ps));
    }

    /* AF_UNIX: ready while listening, deterministic 0 after close+unlink
     * (the path is ours, pid-suffixed: nothing can re-bind it). */
    char upath[128]; snprintf(upath, sizeof upath, "/tmp/fxsock-zig-%d.sock", (int)getpid());
    int ufd = have_sockets ? listen_unix(upath) : -1;
    if (ufd >= 0) {
        expect("unix listening", zig_fx_sock_ready(0, upath), 1);
        close(ufd); unlink(upath);
        expect("unix after close+unlink", zig_fx_sock_ready(0, upath), 0);
    }

    if (fails) { printf("supervise_live: %d FAIL\n", fails); return 1; }
    printf("supervise_live: %d checks PASS\n", checks);
    return 0;
}
