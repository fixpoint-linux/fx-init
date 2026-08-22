/* fx_probe.h — the init-hosted OS probe loop (U-C2).
 *
 * fx-init is the sole writer of the volatile runtime DB.  fx_probe_refresh
 * rebuilds the probe relations from the live system (or a fixture root for
 * tests) inside a single transaction: delete-all existing tuples, then add
 * fresh.  Relations (all fixed arity, declared once at startup):
 *
 *   process(pid, ppid, uid, comm, state, rss_kb)        a6
 *   fs(path, fstype, total_kb, used_kb, avail_kb)        a5
 *   file(path, size, mode, uid, gid, mtime)              a6
 *   device(name, major, minor, type, size)               a5
 *   kernel(version, release, hostname, uptime_s,        a7
 *          load1_x100, mem_total_kb, mem_free_kb)
 *   net(iface, addr, mac, state, rx_bytes, tx_bytes)    a6
 *   env(key, value)                                       a2
 *
 * String columns (comm, state, path, fstype, name, type, version, release,
 * hostname, iface, addr, mac, state, key, value) are interned via
 * dl_intern_str; numeric columns are raw u32. */
#ifndef FX_PROBE_H
#define FX_PROBE_H

#include "dl.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Declare all 7 probe relations in the runtime DB (idempotent).  Returns 0/-1. */
int fx_probe_declare(struct dl_db *rt);

/* Refresh all probe relations (one txn: delete-all + re-add).  `root` is a
 * test-only fixture root that redirects /proc, /sys, /etc reads (NULL => the
 * real /proc, /sys, /etc).  Returns 0/-1; on -1 fills `err`. */
int fx_probe_refresh(struct dl_db *rt, const char *root,
                     char *err, size_t errcap);

#ifdef __cplusplus
}
#endif
#endif /* FX_PROBE_H */
