/* dhake_smoke.c — a fake dhake for the unit-6 in-sandbox differential
 * (init_diff.sh).  fx-init execs `dhake.com -f <bootbf> rootfs`; this fake
 * cats the rewritten buildfile (argv after -f) to stdout — so run_dhake logs
 * it line-by-line and the transcript pins the fx_reloc rewrite — then exits
 * with FAKE_DHAKE_EXIT (default 0; 3 selects the dhake-fail case). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *path = NULL;
    for (int i = 1; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "-f")) { path = argv[i + 1]; break; }
    }
    if (path) {
        FILE *f = fopen(path, "r");
        if (f) {
            char buf[8192];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, f)) > 0) fwrite(buf, 1, n, stdout);
            fclose(f);
        }
    }
    const char *m = getenv("FAKE_DHAKE_EXIT");
    return m ? atoi(m) : 0;
}
