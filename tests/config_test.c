/* tests/config_test.c — unit test for src/config.c (the config.dhall walker).
 *
 * Links: tests/config_test.c + src/config.c + dhall-c core only (NO fxstore,
 * NO datalog-dafsa — config.c is self-contained save for dhall-c + the fx_err
 * inline helper).  Asserts the good fixture parses all fields correctly and
 * each rejection case returns -1 with a sensible error.
 *
 * Build (see tests/build_unit.sh):
 *   cosmocc -std=c11 -O2 -g -Wall -Wextra -I src -I vendor/fxstore \
 *     -I vendor/dhall-c/src -o build-tmp/config_test \
 *     tests/config_test.c src/config.c <dhall-c core 13 files>
 */
#include "fx.h"
#include "fxstore.h"          /* fx_err */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int fails = 0, passes = 0;
#define OK(cond, ...) do { if (cond) { passes++; } else { fails++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* write text to a fresh path under /tmp */
static int write_tmp(char *path, size_t cap, const char *name, const char *text) {
    snprintf(path, cap, "/tmp/cfgtest-%s.dhall", name);
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fputs(text, f);
    fclose(f);
    return 0;
}

static int load(const char *path, FxConfig *c) {
    char err[2048];
    int r = fx_config_load(c, path, err, sizeof err);
    if (r != 0) fprintf(stderr, "  (err: %s)\n", err);
    return r;
}

int main(void) {
    char p[512];
    FxConfig c;

    /* ─── good fixture (from tests/fixtures/config/good.dhall) ─── */
    const char *good = "tests/fixtures/config/good.dhall";
    OK(load(good, &c) == 0, "good config did not load");
    if (load(good, &c) == 0) {
        OK(c.hostname && !strcmp(c.hostname, "fixbox"), "hostname");
        OK(c.npackages == 4 && !strcmp(c.packages[0], "dhake") && !strcmp(c.packages[3], "fake-service"), "packages");
        OK(c.nusers == 2 && !strcmp(c.users[1].name, "alice") && c.users[1].uid == 1000
           && c.users[1].ngroups == 2 && !strcmp(c.users[1].groups[0], "wheel"), "users");
        OK(c.nservices == 2, "nservices");
        OK(!strcmp(c.services[0].name, "heartbeat") && c.services[0].nargv == 2
           && !strcmp(c.services[0].argv[0], "fakesvc"), "svc0 argv");
        OK(c.services[0].on_kind == FX_ON_ALL, "svc0 on=all");
        OK(c.services[0].restart == FX_RESTART_ALWAYS, "svc0 restart=always");
        OK(c.services[0].backoff_ms == 500, "svc0 backoff=500");
        OK(c.services[0].probe_kind == FX_PROBE_FILE && !strcmp(c.services[0].probe_arg, "/run/fx/ready-heartbeat"), "svc0 probe File");
        OK(c.services[0].nenv == 1 && !strcmp(c.services[0].env[0].key, "BEAT") && !strcmp(c.services[0].env[0].value, "hz2"), "svc0 env");
        OK(c.services[0].pkg && !strcmp(c.services[0].pkg, "fake-service"), "svc0 pkg");
        OK(!strcmp(c.services[1].name, "after-heartbeat") && c.services[1].on_kind == FX_ON_UP
           && !strcmp(c.services[1].on_arg, "heartbeat"), "svc1 on=up:heartbeat");
        OK(c.services[1].restart == FX_RESTART_ALWAYS, "svc1 default restart=always");
        OK(c.services[1].backoff_ms == 1000, "svc1 default backoff=1000");
        OK(c.services[1].probe_kind == FX_PROBE_NONE, "svc1 no probe");
        OK(c.services[1].nenv == 0, "svc1 no env");
        OK(c.nextra_etc == 1 && !strcmp(c.extra_etc[0].path, "motd") && !strcmp(c.extra_etc[0].content, "welcome to fixbox"), "extraEtc");
        OK(c.grace_ms == 5000, "bootGraceMs=5000");
        fx_config_free(&c);
    }

    /* ─── rejection cases (embedded; written to /tmp) ─── */
    struct { const char *name; const char *body; } bad[] = {
        { "dup-svc",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let S = { name : Text, argv : List Text, pkg : Optional Text, on : Text, restart : Optional Text, backoffMs : Optional Natural, probe : Optional Probe, env : Optional (List { key : Text, value : Text }) }\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [ { name = \"dup\", argv = [\"a\"], pkg = None Text, on = \"all\", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) }\n"
          "                , { name = \"dup\", argv = [\"b\"], pkg = None Text, on = \"all\", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "on-unknown",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [ { name = \"a\", argv = [\"x\"], pkg = None Text, on = \"up:ghost\", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "bad-restart",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [ { name = \"a\", argv = [\"x\"], pkg = None Text, on = \"all\", restart = Some \"bogus\", backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "bad-on",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [ { name = \"a\", argv = [\"x\"], pkg = None Text, on = \"garbage\", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "empty-argv",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [ { name = \"a\", argv = [] : List Text, pkg = None Text, on = \"all\", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "uid-dup",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text,\n"
          "     users = [ { name = \"a\", uid = 7, groups = [] : List Text }, { name = \"b\", uid = 7, groups = [] : List Text } ],\n"
          "     services = [] : List { name : Text, argv : List Text, pkg : Optional Text, on : Text, restart : Optional Text, backoffMs : Optional Natural, probe : Optional Probe, env : Optional (List { key : Text, value : Text }) },\n"
          "     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }\n" },
        { "etc-abs",
          "let Probe = < Tcp : Natural | Unix : Text | File : Text >\n"
          "let U = { name : Text, uid : Natural, groups : List Text }\n"
          "in { hostname = \"x\", packages = [] : List Text, users = [] : List U,\n"
          "     services = [] : List { name : Text, argv : List Text, pkg : Optional Text, on : Text, restart : Optional Text, backoffMs : Optional Natural, probe : Optional Probe, env : Optional (List { key : Text, value : Text }) },\n"
          "     extraEtc = Some [ { path = \"/etc/host.conf\", content = \"x\" } ], bootGraceMs = None Natural }\n" },
    };
    for (size_t i = 0; i < sizeof bad/sizeof bad[0]; i++) {
        write_tmp(p, sizeof p, bad[i].name, bad[i].body);
        FxConfig bc;
        int r = fx_config_load(&bc, p, (char[2048]){0}, 2048);
        OK(r != 0, "bad config '%s' should be rejected (got %d)", bad[i].name, r);
        if (r == 0) fx_config_free(&bc);
    }

    printf("config_test: %d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
