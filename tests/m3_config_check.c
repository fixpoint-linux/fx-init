/* tests/m3_config_check.c — load each m3/*.dhall config and report pass/fail.
 * Verifies the boot-harness configs are valid config.dhall (the harness can't
 * run in-sandbox, but config validation CAN).  Links config.c + dhall-c only. */
#include "fx.h"
#include <stdio.h>
#include <string.h>

static int check(const char *path) {
    FxConfig c;
    char err[2048];
    int r = fx_config_load(&c, path, err, sizeof err);
    if (r != 0) {
        printf("  FAIL %-30s : %s\n", path, err);
        return 1;
    }
    printf("  ok   %-30s : %d svc, grace=%u, hostname=%s\n",
           path, c.nservices, c.grace_ms, c.hostname ? c.hostname : "?");
    fx_config_free(&c);
    return 0;
}

int main(void) {
    int failed = 0;
    const char *cfgs[] = {
        "m3/config-good.dhall",
        "m3/config-bad-exit.dhall",
        "m3/config-bad-hang.dhall",
    };
    for (size_t i = 0; i < sizeof cfgs/sizeof cfgs[0]; i++)
        failed += check(cfgs[i]);
    printf("m3_config_check: %d checked, %d failed\n",
           (int)(sizeof cfgs/sizeof cfgs[0]), failed);
    return failed ? 1 : 0;
}
