/* fxctl_dump.c — the C ORACLE for the fxctl-port request-line differential
 * (part 1 of fxctl_diff.sh): prints the request line fxctl would send, given
 * argv.  The request-line builder + usage live INLINE in fxctl.c's main()
 * (fxctl.c:107-134), so linking src/fxctl.c here would drag in the real
 * main() and its socket connect; this oracle therefore carries those two
 * pieces VERBATIM (same guards, byte-for-byte).  Any drift between this copy
 * and fxctl.c is caught by part 2 of the harness (fxctl_live.c), which execs
 * the UNMODIFIED C client against a fake fx-init server and byte-compares
 * stdout+stderr+rc against the Zig client — the echoed request pins the real
 * main()'s request bytes, including the 4096 cap.
 *
 * Output: "req[<len>]=<<line>>\n" rc 0; no subcommand -> usage on stderr rc 2.
 */
#include <stdio.h>
#include <string.h>

#define LINE_MAX_REQ 4096

static void usage(void) {
    fprintf(stderr,
        "usage: fxctl <subcommand> [args]\n"
        "  status | q <rel> [vals..] | start|stop|restart <svc> | probe\n"
        "  activate <config> | rollback <ver> | shutdown\n"
        "  grep <regex> | search <term> [term..]\n"
        "env: FX_RUN (default /run/fx), FX_SOCKET (override control.sock path)\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }

    /* verbatim from fxctl.c main() (fxctl.c:119-134) */
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

    printf("req[%zu]=<%s>\n", off, req);
    return 0;
}
