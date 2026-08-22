/* fx_log.c — (U-C2) the DAFSA-interned service log DB.
 *
 * fx_log_open / fx_log_emit / fx_log_grep / fx_log_search / fx_log_rotate.
 * Uses datalog-dafsa's dl_intern_str (DAFSA interning so repeated messages
 * collapse to one sym), aux_index_add_posting + tokenize for full-text AND
 * search, and regex_compile + dl_pattern for regex.  See fx_log.h.
 *
 * The semantic/vector half of the design's "HYBRID" search is out of scope for
 * the C binary (dl-embed is an opt-in C++/ggml tool requiring the bge-small
 * model; vendor/ggml is excluded from packages) — v1 ships regex + token
 * full-text; dl_vector_* is the future hook.
 */
#include "fx_log.h"
#include "index.h"
#include "regexwalk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ─── emit ──────────────────────────────────────────────────────────────── */

int fx_log_emit(struct dl_db *db, uint32_t ts,
                const char *svc, const char *level, const char *msg) {
    if (!db) return -1;
    uint32_t s = dl_intern_str(db, svc);
    uint32_t l = dl_intern_str(db, level);
    uint32_t m = dl_intern_str(db, msg);
    if (!s || !l || !m) return -1;
    uint32_t cols[4] = { ts, s, l, m };
    if (dl_add_fact(db, "log", cols, 4) < 0) return -1;
    /* postings: tokenize the message, intern each token, link term->msg_sym */
    size_t ntok = 0;
    char **toks = tokenize(msg, &ntok);
    if (toks) {
        for (size_t i = 0; i < ntok; i++) {
            uint32_t tsym = dl_intern_str(db, toks[i]);
            if (tsym) aux_index_add_posting(db, tsym, m);
        }
        token_free(toks);
    }
    return 0;
}

uint64_t fx_log_count(struct dl_db *db) {
    if (!db) return UINT64_MAX;
    return dl_count(db, "log");
}

/* ─── grep (regex on the msg column) ────────────────────────────────────
 * regexwalk is FULL-KEY match (implicit ^...$), so wrap the pattern in
 * .* ... .* for substring matching. */
typedef struct {
    struct dl_db *db;
    fx_log_cb cb;
    void *user;
    long n;
} GrepState;

static int grep_inner(const uint32_t *cols, uint8_t arity, void *user) {
    (void)arity;
    GrepState *g = (GrepState *)user;
    uint32_t ts = cols[0];
    const char *svc = dl_intern_str_of(g->db, cols[1]);
    const char *lvl = dl_intern_str_of(g->db, cols[2]);
    const char *mstr = dl_intern_str_of(g->db, cols[3]);
    if (!svc) svc = "?";
    if (!lvl) lvl = "?";
    if (!mstr) mstr = "?";
    g->n++;
    if (g->cb(ts, svc, lvl, mstr, g->user)) return 1;
    return 0;
}

long fx_log_grep(struct dl_db *db, const char *regex, fx_log_cb cb, void *user) {
    if (!db || !regex || !cb) return -1;
    size_t n = strlen(regex);
    char *pat = malloc(n + 5);
    if (!pat) return -1;
    memcpy(pat, ".*", 2);
    memcpy(pat + 2, regex, n);
    memcpy(pat + 2 + n, ".*", 2);
    pat[n + 4] = '\0';
    regex_dfa *dfa = regex_compile(pat);
    free(pat);
    if (!dfa) return -1;
    if (dfa->errmsg) { regex_dfa_free(dfa); return -1; }

    /* dl_pattern enumerates tuples whose COL 3 (msg) matches; we resolve the
     * other cols into strings via the interner and stream to user cb. */
    GrepState g = { db, cb, user, 0 };
    long r = dl_pattern(db, "log", 3, dfa, grep_inner, &g);
    regex_dfa_free(dfa);
    if (r < 0) return -1;
    return g.n;
}

/* ─── search (AND of interned tokens via dl_search) ────────────────────────
 * dl_search returns msg_syms matching ALL terms; we then enumerate log
 * tuples in ascending order, filtering where col 3 == one of the matched
 * msg_syms. */
typedef struct {
    uint32_t *a;
    size_t *n;
    size_t cap;
    int overflow;
} MatchState;

static int search_collect(uint32_t obs_id, int score, void *user) {
    (void)score;
    MatchState *m = (MatchState *)user;
    if (*m->n >= m->cap) { m->overflow = 1; return 1; }
    m->a[(*m->n)++] = obs_id;
    return 0;
}

long fx_log_search(struct dl_db *db, const char *const *terms, int nterms,
                   fx_log_cb cb, void *user) {
    if (!db || !cb || nterms <= 0) return -1;
    uint32_t *tsyms = malloc((size_t)nterms * sizeof *tsyms);
    if (!tsyms) return -1;
    for (int i = 0; i < nterms; i++) {
        tsyms[i] = dl_intern_str(db, terms[i]);
        if (!tsyms[i]) { free(tsyms); return -1; }
    }
    size_t cap = (size_t)nterms * 16;
    if (cap < 16) cap = 16;
    uint32_t *matched = malloc(cap * sizeof *matched);
    if (!matched) { free(tsyms); return -1; }
    size_t nmatch = 0;
    MatchState m = { matched, &nmatch, cap, 0 };
    long r = dl_search(db, tsyms, nterms, search_collect, &m);
    free(tsyms);
    if (r < 0) { free(matched); return -1; }

    long emitted = 0;
    dl_iter *it = dl_iter_open(db, "log", NULL, 0);
    if (!it) { free(matched); return -1; }
    uint8_t arity = dl_iter_arity(it);
    if (arity != 4) { dl_iter_close(it); free(matched); return -1; }
    uint32_t cols[4];
    while (dl_iter_next(it, cols) == 1) {
        uint32_t msg = cols[3];
        int hit = 0;
        for (size_t i = 0; i < nmatch; i++) {
            if (matched[i] == msg) { hit = 1; break; }
        }
        if (!hit) continue;
        const char *svc = dl_intern_str_of(db, cols[1]);
        const char *lvl = dl_intern_str_of(db, cols[2]);
        const char *mstr = dl_intern_str_of(db, cols[3]);
        if (!svc) svc = "?";
        if (!lvl) lvl = "?";
        if (!mstr) mstr = "?";
        emitted++;
        if (cb(cols[0], svc, lvl, mstr, user)) break;
    }
    dl_iter_close(it);
    free(matched);
    return emitted;
}

/* ─── open/close/rotate ──────────────────────────────────────────────────── */

struct dl_db *fx_log_open(const char *path) {
    struct dl_db *db = dl_open(path);
    if (!db) return NULL;
    if (dl_declare_relation(db, "log", 4) != 0) { dl_close(db); return NULL; }
    if (aux_index_ensure_postings(db) != 0) { dl_close(db); return NULL; }
    return db;
}

void fx_log_close(struct dl_db *db) { if (db) dl_close(db); }

int fx_log_rotate(struct dl_db *db, uint64_t cap) {
    if (!db) return -1;
    uint64_t n = dl_count(db, "log");
    if (n == UINT64_MAX) return -1;
    if (n <= cap) return 0;
    uint64_t drop = n / 4;  /* oldest quarter */
    if (drop == 0) return 0;
    /* ts is the leading column; ascending lex order == ascending ts order, so
     * the first `drop` tuples are the oldest.
     *
     * COLLECT-then-DELETE (same pattern as fx-activate's clear_rel and fx-init's
     * restore_m4_facts): we first collect the oldest `drop` tuples into a
     * buffer with the iterator CLOSED, then delete them in one txn.  Deleting
     * inside the dl_iter_next loop (the old code) mutates the live DAFSA cursor
     * the iterator is walking — inconsistent with the rest of the codebase and
     * a latent risk if datalog-dafsa's txn-deferred-delete semantics ever
     * change.  Collect-then-delete is safe vs the cursor regardless. */
    dl_iter *it = dl_iter_open(db, "log", NULL, 0);
    if (!it) return -1;
    uint8_t ar = dl_iter_arity(it);
    if (ar != 4) { dl_iter_close(it); return -1; }
    uint32_t *bag = malloc((size_t)drop * ar * sizeof *bag);
    if (!bag) { dl_iter_close(it); return -1; }
    uint64_t k = 0;
    uint32_t row[4];
    while (k < drop && dl_iter_next(it, row) == 1) {
        memcpy(&bag[k * ar], row, ar * sizeof *row);
        k++;
    }
    dl_iter_close(it);
    if (dl_txn_begin(db) != 0) { free(bag); return -1; }
    for (uint64_t i = 0; i < k; i++)
        dl_txn_delete_fact(db, "log", &bag[i * ar], ar);
    if (dl_txn_commit(db) != 0) { dl_txn_rollback(db); free(bag); return -1; }
    free(bag);
    return 0;
}
