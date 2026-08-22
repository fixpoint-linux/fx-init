/* fx_supervise.c — pure supervision helpers (see fx_supervise.h).
 *
 * Extracted from fx-init.c so the on=sock: readiness connect, the restart
 * backoff math + 60s-stable reset, and the ms-precision boot grace deadline
 * can be unit tested in isolation (fx-init.c has main() and is not linkable
 * as a library).  No global state, no store DB, no dhall — linkable into a
 * unit test by itself. */
#include "fx_supervise.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <sys/un.h>

/* ─── on=sock: readiness gate + Tcp/Unix probe ─────────────────────────── */

int fx_sock_ready(int tcp, const char *arg) {
    if (!arg || !*arg) return 0;
    /* 250ms connect timeout (defensive): localhost/unix connects return fast
     * (ECONNREFUSED/ENOENT), but a slow endpoint must not hang the poll loop. */
    struct timeval to = { .tv_sec = 0, .tv_usec = 250000 };
    int fd;
    if (tcp) {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return 0;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port = htons((uint16_t)strtoul(arg, NULL, 10));
        a.sin_addr.s_addr = htonl(0x7f000001u);  /* 127.0.0.1 */
        int ok = (connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
        close(fd);
        return ok ? 1 : 0;
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, arg, sizeof a.sun_path - 1);
    int ok = (connect(fd, (struct sockaddr *)&a, sizeof a) == 0);
    close(fd);
    return ok ? 1 : 0;
}

/* ─── restart backoff ──────────────────────────────────────────────────── */

uint32_t fx_backoff_sleep_ms(uint32_t cur_backoff, uint32_t base_ms) {
    uint32_t bo = cur_backoff ? cur_backoff : base_ms;
    if (bo == 0) bo = 1000;
    if (bo > FX_BACKOFF_CAP_MS) bo = FX_BACKOFF_CAP_MS;
    return bo;
}

uint32_t fx_backoff_next(uint32_t sleep_ms) {
    uint32_t n = sleep_ms * 2;
    if (n > FX_BACKOFF_CAP_MS) n = FX_BACKOFF_CAP_MS;
    /* guard against sleep_ms==0 producing a stuck-zero next (shouldn't happen
     * since fx_backoff_sleep_ms never returns 0, but be defensive) */
    if (n == 0) n = FX_BACKOFF_CAP_MS;
    return n;
}

int fx_backoff_should_reset(uint32_t stable_ms) {
    return stable_ms >= FX_BACKOFF_STABLE_MS;
}

/* ─── boot grace deadline (ms-precision) ──────────────────────────────── */

uint64_t fx_boot_deadline_ms(uint64_t start_ms, uint32_t grace_ms) {
    return start_ms + (uint64_t)grace_ms;
}

int fx_boot_grace_expired(uint64_t now_ms, uint64_t deadline_ms) {
    return now_ms >= deadline_ms;
}
