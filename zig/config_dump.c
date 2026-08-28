/* config_dump.c — the C ORACLE for the config-port differential harness.
 *
 * Links the EXISTING src/config.c + the vendored dhall-c C core (same 13-file
 * list as tests/build_unit.sh) and prints the FULL FxConfig to stdout in a
 * STABLE canonical format (one line per field, in FxConfig order):
 *
 *   hostname=...
 *   package[i]=...
 *   user[i].name / user[i].uid / user[i].groups[j]=...
 *   service[i].name / .argv[j] / .pkg / .on_kind / .on_arg / .restart /
 *     .backoff_ms / .probe_kind / .probe_arg / .env[j].key=...
 *   etc[i].path= / etc[i].content=
 *   grace_ms=...
 *
 * Absent optionals print as "-".  On load error: prints
 *   fx-config-dump: <err>
 * to stderr and exits 1.
 *
 * Build (see config_diff.sh):
 *   zig cc -std=c11 -O2 -I ../src -I ../vendor/fxstore -I ../vendor/dhall-c/src \
 *     -o zig-out/config_dump config_dump.c ../src/config.c <dhall-c 13 C files>
 */
#include "fx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *on_kind_name(FxOnKind k) {
    switch (k) {
    case FX_ON_ALL: return "FX_ON_ALL";
    case FX_ON_UP: return "FX_ON_UP";
    case FX_ON_SOCK_TCP: return "FX_ON_SOCK_TCP";
    case FX_ON_SOCK_UNIX: return "FX_ON_SOCK_UNIX";
    case FX_ON_TIME: return "FX_ON_TIME";
    case FX_ON_NET: return "FX_ON_NET";
    }
    return "?";
}

static const char *probe_kind_name(FxProbeKind k) {
    switch (k) {
    case FX_PROBE_NONE: return "FX_PROBE_NONE";
    case FX_PROBE_TCP: return "FX_PROBE_TCP";
    case FX_PROBE_UNIX: return "FX_PROBE_UNIX";
    case FX_PROBE_FILE: return "FX_PROBE_FILE";
    }
    return "?";
}

static const char *restart_name(FxRestart r) {
    switch (r) {
    case FX_RESTART_ALWAYS: return "FX_RESTART_ALWAYS";
    case FX_RESTART_ON_FAILURE: return "FX_RESTART_ON_FAILURE";
    case FX_RESTART_NEVER: return "FX_RESTART_NEVER";
    }
    return "?";
}

static void dump(const FxConfig *c) {
    printf("hostname=%s\n", c->hostname ? c->hostname : "-");
    for (int i = 0; i < c->npackages; i++)
        printf("package[%d]=%s\n", i, c->packages[i]);
    for (int i = 0; i < c->nusers; i++) {
        printf("user[%d].name=%s\n", i, c->users[i].name ? c->users[i].name : "-");
        printf("user[%d].uid=%u\n", i, c->users[i].uid);
        for (int j = 0; j < c->users[i].ngroups; j++)
            printf("user[%d].groups[%d]=%s\n", i, j, c->users[i].groups[j]);
    }
    for (int i = 0; i < c->nservices; i++) {
        const FxService *s = &c->services[i];
        printf("service[%d].name=%s\n", i, s->name ? s->name : "-");
        for (int j = 0; j < s->nargv; j++)
            printf("service[%d].argv[%d]=%s\n", i, j, s->argv[j]);
        printf("service[%d].pkg=%s\n", i, s->pkg ? s->pkg : "-");
        printf("service[%d].on_kind=%s\n", i, on_kind_name(s->on_kind));
        printf("service[%d].on_arg=%s\n", i, s->on_arg ? s->on_arg : "-");
        printf("service[%d].restart=%s\n", i, restart_name(s->restart));
        printf("service[%d].backoff_ms=%u\n", i, s->backoff_ms);
        printf("service[%d].probe_kind=%s\n", i, probe_kind_name(s->probe_kind));
        printf("service[%d].probe_arg=%s\n", i, s->probe_arg ? s->probe_arg : "-");
        for (int j = 0; j < s->nenv; j++) {
            printf("service[%d].env[%d].key=%s\n", i, j, s->env[j].key);
            printf("service[%d].env[%d].value=%s\n", i, j, s->env[j].value);
        }
    }
    for (int i = 0; i < c->nextra_etc; i++) {
        printf("etc[%d].path=%s\n", i, c->extra_etc[i].path);
        printf("etc[%d].content=%s\n", i, c->extra_etc[i].content);
    }
    printf("grace_ms=%u\n", c->grace_ms);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: config_dump <config.dhall>\n");
        return 2;
    }
    FxConfig c;
    char err[2048];
    if (fx_config_load(&c, argv[1], err, sizeof err) != 0) {
        fprintf(stderr, "fx-config-dump: %s\n", err);
        return 1;
    }
    dump(&c);
    fx_config_free(&c);
    return 0;
}
