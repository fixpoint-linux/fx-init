/* reloc_dump.c — the C ORACLE for the reloc-port differential harness.
 *
 * Links the EXISTING src/fx_reloc.c and drives fx_reloc_rewrite_buildfile,
 * printing the rewritten buildfile to stdout in a stable format:
 *
 *   rc 0, success:  "OK <n>\n" then the rewritten bytes verbatim + "\n"
 *   rc 0, NULL:     "NULL\n"
 *   rc 1, NULL:     "NULL\n"  (failure: malformed buildfile / no '/')
 *
 * Input: argv[1] = path to the buildfile text, argv[2] = new_store.  ("NULL"
 * is ambiguous on purpose — the harness pins stdout+rc, and the C returns
 * NULL both for "rejected" and "nothing to do", so one word covers both.)
 *
 * Build (see reloc_diff.sh):
 *   zig cc -std=gnu11 -O2 -I ../src -o zig-out/reloc_dump \
 *     reloc_dump.c ../src/fx_reloc.c
 */
#include "fx_reloc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: reloc_dump <buildfile> <new_store>\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        fprintf(stderr, "fx-reloc-dump: cannot open %s\n", argv[1]);
        return 1;
    }
    /* read the whole file: text bytes + NUL terminator */
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 1; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return 1; }
    rewind(f);
    char *text = malloc((size_t)sz + 1);
    if (!text) { fclose(f); return 1; }
    if (fread(text, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); free(text); return 1; }
    text[sz] = '\0';
    fclose(f);

    char *out = fx_reloc_rewrite_buildfile(text, argv[2]);
    if (!out) {
        printf("NULL\n");
        return 1;
    }
    printf("OK %zu\n%s\n", strlen(out), out);
    free(out);
    free(text);
    return 0;
}
