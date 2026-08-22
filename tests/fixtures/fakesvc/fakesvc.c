/* tests/fixtures/fakesvc/fakesvc.c — a tiny cosmocc APE used by the M4 boot
 * harness to exercise fx-init supervision paths.  argv[1] selects the mode:
 *
 *   ok          print "heartbeat from <FX_SVC_NAME|fakesvc>" every 500ms forever
 *   exit <code> sleep 100ms then exit(atoi(code))
 *   hang        pause() forever (never reaches ready/started gate)
 *   net <port>  bind/listen 127.0.0.1:port, accept+echo one connection per loop
 *
 * fx-init sets FX_SVC_NAME + FX_RUN_DIR + PATH=/bin in the child env and pipes
 * stdout/stderr into the log DB, so "ok" output is what tests/fxinit_boot.sh
 * greps for ("heartbeat"). */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const char *svcname(void) {
    const char *n = getenv("FX_SVC_NAME");
    return n ? n : "fakesvc";
}

static int mode_ok(void) {
    /* write a readiness marker if requested, then heartbeat forever */
    const char *ready = getenv("FX_READY_FILE");
    if (ready) { FILE *f = fopen(ready, "w"); if (f) { fputs("ready\n", f); fclose(f); } }
    for (;;) {
        printf("heartbeat from %s\n", svcname());
        fflush(stdout);
        usleep(500 * 1000);
    }
    return 0;  /* unreachable */
}

static int mode_exit(char *code) {
    usleep(100 * 1000);
    int c = code ? (int)strtol(code, NULL, 10) : 0;
    printf("fakesvc exit %d\n", c);
    fflush(stdout);
    return c;
}

static int mode_hang(void) {
    printf("fakesvc hang\n");
    fflush(stdout);
    for (;;) pause();
    return 0;
}

static int mode_net(char *port) {
    int p = port ? (int)strtol(port, NULL, 10) : 0;
    if (p <= 0) { fprintf(stderr, "fakesvc net: bad port\n"); return 2; }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 2; }
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)p);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); close(s); return 2; }
    if (listen(s, 4) < 0) { perror("listen"); close(s); return 2; }
    printf("fakesvc net listening %d\n", p);
    fflush(stdout);
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        dprintf(c, "hello from %s\n", svcname());
        close(c);
    }
    return 0;
}

int main(int argc, char **argv) {
    /* ignore SIGTERM so the harness can verify fx-init escalates to SIGKILL
     * if a child refuses to die within the shutdown grace — but actually we
     * WANT default SIGTERM handling (so shutdown sweep works); do NOT block. */
    (void)argc;
    if (argc < 2) { fprintf(stderr, "usage: fakesvc <ok|exit <code>|hang|net <port>>\n"); return 2; }
    if (!strcmp(argv[1], "ok"))    return mode_ok();
    if (!strcmp(argv[1], "exit")) return mode_exit(argc > 2 ? argv[2] : "0");
    if (!strcmp(argv[1], "hang")) return mode_hang();
    if (!strcmp(argv[1], "net"))  return mode_net(argc > 2 ? argv[2] : NULL);
    fprintf(stderr, "fakesvc: unknown mode %s\n", argv[1]);
    return 2;
}
