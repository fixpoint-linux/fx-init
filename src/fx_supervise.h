/* fx_supervise.h — pure helpers extracted from the fx-init supervisor (fx-init.c)
 * so the readiness-gate, restart-backoff, and boot-grace logic can be unit
 * tested in isolation.  fx-init.c has main() and is not linkable as a library,
 * so the small pure pieces of the supervision policy live here.
 *
 *   fx_sock_ready       — on=sock:tcp/unix readiness gate AND Tcp/Unix probe
 *   fx_backoff_*        — restart backoff (sleep / next / 60s-stable reset)
 *   fx_boot_deadline_ms — boot grace deadline (ms-precision, no /1000 truncation)
 *   fx_boot_grace_expired
 */
#ifndef FX_SUPERVISE_H
#define FX_SUPERVISE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── on=sock: readiness gate + Tcp/Unix probe ───────────────────────────
 * Attempt a connect to a local readiness socket.  Returns 1 on success
 * (the socket accepts), 0 on failure (refused/timeout/no listener).  Used by
 * both the on=sock:tcp/unix readiness gate in on_ready() and the Tcp/Unix
 * probe in probe_ready() — the connect contract is identical.
 *   tcp=1  -> AF_INET 127.0.0.1:<arg decimal port>
 *   tcp=0  -> AF_UNIX <arg absolute path>
 * arg NULL or empty => 0 (no connect attempted). */
int fx_sock_ready(int tcp, const char *arg);

/* ─── restart backoff ──────────────────────────────────────────────────── */
#define FX_BACKOFF_CAP_MS    30000u   /* doubling cap (30s)                      */
#define FX_BACKOFF_STABLE_MS 60000u   /* reset to base after 60s ST_STARTED       */

/* Sleep duration (ms) for the next restart, given the current backoff state.
 * cur=0 => use base; base=0 => 1000; clamped to FX_BACKOFF_CAP_MS. */
uint32_t fx_backoff_sleep_ms(uint32_t cur_backoff, uint32_t base_ms);
/* New cur_backoff to store after a restart (the slept value doubled, capped). */
uint32_t fx_backoff_next(uint32_t sleep_ms);
/* 1 if a service that has been ST_STARTED for `stable_ms` should reset its
 * accumulated backoff to base (the design's "reset after 60s stable"). */
int fx_backoff_should_reset(uint32_t stable_ms);

/* ─── boot grace deadline (ms-precision) ────────────────────────────────
 * The old `g_boot_start + g_grace_ms/1000` truncated sub-second grace values
 * (1500ms -> 1s deadline).  These helpers keep the deadline in ms so sub-
 * second grace is honored. */
/* Absolute ms deadline = start_ms + grace_ms. */
uint64_t fx_boot_deadline_ms(uint64_t start_ms, uint32_t grace_ms);
/* 1 if `now_ms` has reached/passed the deadline. */
int fx_boot_grace_expired(uint64_t now_ms, uint64_t deadline_ms);

#ifdef __cplusplus
}
#endif
#endif /* FX_SUPERVISE_H */
