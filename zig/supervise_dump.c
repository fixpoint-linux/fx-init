/* supervise_dump.c — the C ORACLE for the supervise-port differential
 * harness (pure-math part): drives fx_backoff_sleep_ms / fx_backoff_next /
 * fx_backoff_should_reset / fx_boot_deadline_ms / fx_boot_grace_expired over
 * a deterministic sweep and prints one line per case.  fx_sock_ready is NOT
 * swept here (live I/O; exercised separately against real sockets, see
 * supervise_diff.sh + the unit tests).
 *
 * Links tests/build_supervise.sh style: supervise_dump.c + src/fx_supervise.c
 * only (no store DB, no dhall-c).
 */
#include "fx_supervise.h"

#include <stdio.h>
#include <stdint.h>

int main(void) {
    /* ── fx_backoff_sleep_ms: cur x base ─────────────────────────────────── */
    {
        static const uint32_t curs[] = {
            0, 1, 500, 1000, 1500, 29999, 30000, 30001,
            0xFFFFFFFFu /* wrap-around top */
        };
        static const uint32_t bases[] = { 0, 1, 999, 1000, 29999, 30000 };
        for (size_t i = 0; i < sizeof curs / sizeof curs[0]; i++)
            for (size_t j = 0; j < sizeof bases / sizeof bases[0]; j++)
                printf("sleep(%u,%u)=%u\n", curs[i], bases[j],
                       fx_backoff_sleep_ms(curs[i], bases[j]));
    }

    /* ── fx_backoff_next: boundary set + u32 overflow (15000000*2 wraps) ── */
    {
        static const uint32_t sleeps[] = {
            0, 1, 2, 999, 1000, 14999, 15000, 15001, 20000, 29999, 30000,
            30001, 0x7FFFFFFFu, 0x80000000u, 0xFFFFFFFFu
        };
        for (size_t i = 0; i < sizeof sleeps / sizeof sleeps[0]; i++)
            printf("next(%u)=%u\n", sleeps[i], fx_backoff_next(sleeps[i]));
    }

    /* ── fx_backoff_should_reset: 60s boundary ───────────────────────────── */
    {
        static const uint32_t stables[] = {
            0, 1, 59998, 59999, 60000, 60001, 120000, 0xFFFFFFFFu
        };
        for (size_t i = 0; i < sizeof stables / sizeof stables[0]; i++)
            printf("reset(%u)=%d\n", stables[i],
                   fx_backoff_should_reset(stables[i]));
    }

    /* ── fx_boot_deadline_ms: incl u64 overflow (start near 2^64) ───────── */
    {
        static const uint64_t starts[] = {
            0, 1, 999, 100000, 1500,
            0xFFFFFFFFFFFFFFF8ull, 0xFFFFFFFFFFFFFFFFull /* wrap starts */
        };
        static const uint32_t graces[] = {
            0, 1, 500, 1500, 5000, 30000, 60000, 0xFFFFFFFFu
        };
        for (size_t i = 0; i < sizeof starts / sizeof starts[0]; i++)
            for (size_t j = 0; j < sizeof graces / sizeof graces[0]; j++)
                printf("deadline(%llu,%u)=%llu\n",
                       (unsigned long long)starts[i], graces[j],
                       (unsigned long long)fx_boot_deadline_ms(starts[i], graces[j]));
    }

    /* ── fx_boot_grace_expired: at/past deadline + both-max wrap ─────────── */
    {
        static const uint64_t pairs[][2] = {
            {0, 0}, {0, 1}, {1, 1}, {1499, 1500}, {1500, 1500}, {2000, 1500},
            {0xFFFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull},
            {0xFFFFFFFFFFFFFFFEull, 0xFFFFFFFFFFFFFFFFull},
        };
        for (size_t i = 0; i < sizeof pairs / sizeof pairs[0]; i++)
            printf("expired(%llu,%llu)=%d\n",
                   (unsigned long long)pairs[i][0],
                   (unsigned long long)pairs[i][1],
                   fx_boot_grace_expired(pairs[i][0], pairs[i][1]));
    }
    return 0;
}
