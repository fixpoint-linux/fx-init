/* fx_log.h — the DAFSA-interned service log DB (U-C2).
 *
 * A SEPARATE datalog DB (per design) from the runtime DB, held for life by
 * fx-init.  Relations:
 *   log(ts_epoch_s : u32, svc : sym, level : sym, msg : sym)  a4
 * plus the auxiliary postings index __postings__(term_sym, msg_sym) a2 used by
 * dl_search for full-text AND queries.  svc/level/msg are interned via
 * dl_intern_str so repeated text collapses to one sym (DAFSA interning). */
#ifndef FX_LOG_H
#define FX_LOG_H

#include "dl.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open (create) the log DB at `path` and declare its relations.  Held for
 * life by fx-init (the sole writer).  Returns the handle or NULL on error. */
struct dl_db *fx_log_open(const char *path);
void fx_log_close(struct dl_db *db);

/* Append one log line.  ts is a unix epoch-second timestamp; svc/level/msg
 * are interned (duplicates collapse).  Returns 0/-1. */
int fx_log_emit(struct dl_db *db, uint32_t ts,
                const char *svc, const char *level, const char *msg);

/* Number of log tuples.  UINT64_MAX on error. */
uint64_t fx_log_count(struct dl_db *db);

/* Stream each matching log line via cb (ascending).  Return non-zero from cb
 * to stop early.  Returns the count emitted, or -1 on error. */
typedef int (*fx_log_cb)(uint32_t ts, const char *svc, const char *level,
                        const char *msg, void *user);
long fx_log_grep(struct dl_db *db, const char *regex, fx_log_cb cb, void *user);
long fx_log_search(struct dl_db *db, const char *const *terms, int nterms,
                   fx_log_cb cb, void *user);

/* Rotation: if the log exceeds cap tuples, drop the oldest quarter (by ts).
 * Called periodically by fx-init.  Returns 0/-1. */
int fx_log_rotate(struct dl_db *db, uint64_t cap);

#ifdef __cplusplus
}
#endif
#endif /* FX_LOG_H */
