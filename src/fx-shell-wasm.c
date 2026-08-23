/* fx-shell-wasm.c — browser shell entry point for the fx-init userland demo.
 *
 * Compiled to WebAssembly via emscripten INSTEAD of the native binaries: this
 * file defines the entry surface; the tools' own main()s are linked in as
 * separate translation units with per-TU renames (-Dmain=fxstore_main etc.,
 * see scripts/build-wasm.sh) and dispatched from here. Exports:
 *
 *   int fxsh_run(const char *cmdline)
 *
 * Tokenizes cmdline POSIX-ish (single/double quotes group, backslash escapes),
 * looks up argv[0] in the command table, and calls the tool's renamed
 * main(argc, argv). Returns the tool's exit code; 127 unknown command,
 * 126 tokenize failure, 0 empty line.
 *
 * All tool output goes to stdout/stderr (emscripten Module.print/printErr).
 * The MEMFS virtual filesystem persists across calls: one page session = one
 * running system, /fx/store included. The JS driver FS.chdir()s before calls;
 * tools resolve relative paths (package-set.dhall, config.dhall) against that
 * cwd, exactly like on a real host. fxctl is compiled in on purpose: with no
 * PID1 and no AF_UNIX socket in a browser it prints its REAL not-running
 * error — that honest failure is part of the demo's story.
 */
#include <emscripten.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int fxstore_main(int argc, char **argv);
int fx_activate_main(int argc, char **argv);
int fxctl_main(int argc, char **argv);
int dhall_main(int argc, char **argv);

typedef int (*tool_main)(int, char **);

static const struct { const char *name; tool_main fn; } TOOLS[] = {
    { "fxstore",     fxstore_main },
    { "fx-activate", fx_activate_main },
    { "fxctl",       fxctl_main },
    { "dhall",       dhall_main },
};

#define MAX_ARGV 64

/* Split cmdline into argv (in place over a mutable copy). POSIX-ish: quotes
 * group, backslash escapes the next char. Returns argc, or -1 on error. */
static int tokenize(char *copy, char *argv[MAX_ARGV]) {
    int argc = 0;
    char *p = copy;
    while (*p) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        if (argc >= MAX_ARGV - 1) return -1;
        char *out = p, *w = p;
        while (*p && *p != ' ' && *p != '\t') {
            if (*p == '\\' && p[1]) { p++; *w++ = *p++; }
            else if (*p == '\'' || *p == '"') {
                char q = *p++;
                while (*p && *p != q) {
                    if (q == '"' && *p == '\\' && p[1]) p++; /* keep escape */
                    *w++ = *p++;
                }
                if (*p == q) p++; else return -1; /* unterminated quote */
            } else *w++ = *p++;
        }
        if (*p) p++;  /* consume the delimiter (space/tab) the word loop stopped at */
        *w = '\0';
        argv[argc++] = out;
    }
    argv[argc] = NULL;
    return argc;
}

EMSCRIPTEN_KEEPALIVE
int fxsh_run(const char *cmdline) {
    if (!cmdline) return 126;
    char *copy = strdup(cmdline);
    if (!copy) return 126;
    char *argv[MAX_ARGV];
    int argc = tokenize(copy, argv);
    if (argc < 0) { printf("fxsh: parse error\n"); free(copy); return 126; }
    if (argc == 0) { free(copy); return 0; }

    tool_main fn = NULL;
    for (size_t i = 0; i < sizeof TOOLS / sizeof TOOLS[0]; i++)
        if (strcmp(argv[0], TOOLS[i].name) == 0) { fn = TOOLS[i].fn; break; }

    int rc;
    if (!fn) {
        printf("fxsh: command not found: %s\n", argv[0]);
        printf("fxsh: wasm commands: fxstore fx-activate fxctl dhall; shell builtins: help ls cat pwd clear\n");
        rc = 127;
    } else {
        rc = fn(argc, argv);
    }
    fflush(stdout);
    fflush(stderr);
    free(copy);
    return rc;
}
