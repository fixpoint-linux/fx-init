/* fx_reloc.c — store-relocatability rewrite (see fx_reloc.h).  Pure string
 * transform, no global state, no I/O — unit-testable standalone. */
#include "fx_reloc.h"

#include <stdlib.h>
#include <string.h>

/* Locate the closing quote of a Dhall "..." string literal starting at `open`
 * (which points just AFTER the opening ").  Handles \" and \\ escapes.  Returns
 * a pointer to the closing ", or NULL if unterminated. */
static const char *dhall_str_end(const char *open) {
    const char *q = open;
    while (*q) {
        if (*q == '\\' && q[1]) q += 2;        /* escaped char: skip both */
        else if (*q == '"') return q;          /* closing quote */
        else q++;
    }
    return NULL;
}

char *fx_reloc_rewrite_buildfile(const char *text, const char *new_store) {
    if (!text || !new_store) return NULL;

    /* find the `let GEN = "..."` binding and extract the host store root */
    static const char marker[] = "let GEN = \"";
    const char *gen = strstr(text, marker);
    if (!gen) return NULL;                       /* not our buildfile shape */
    const char *path_start = gen + sizeof marker - 1;  /* after the opening " */
    const char *path_end = dhall_str_end(path_start);
    if (!path_end) return NULL;                   /*unterminated string literal*/

    /* host store root = GEN path up to (but not including) its last '/'. */
    const char *last_slash = NULL;
    for (const char *p = path_start; p < path_end; p++)
        if (*p == '/') last_slash = p;
    if (!last_slash) return NULL;                 /* GEN has no '/' — no root to rewrite */

    size_t root_len = (size_t)(last_slash - path_start);
    size_t text_len = strlen(text);
    size_t new_len  = strlen(new_store);

    /* host root "/" => GEN already /-absolute; nothing sensible to rewrite,
     * return a verbatim copy so the caller can still exec dhake on it. */
    if (root_len == 0) {
        char *out = malloc(text_len + 1);
        if (!out) return NULL;
        memcpy(out, text, text_len + 1);
        return out;
    }

    /* NUL-terminate the host root so strstr/memcmp can compare it. */
    char *host_root = malloc(root_len + 1);
    if (!host_root) return NULL;
    memcpy(host_root, path_start, root_len);
    host_root[root_len] = '\0';

    /* count occurrences for output sizing (single pass, no overlap: we always
     * advance past a match by root_len, and host_root cannot overlap itself
     * because replacement is a separate emit phase over the original text). */
    size_t occ = 0;
    {
        const char *s = text;
        while ((s = strstr(s, host_root)) != NULL) { occ++; s += root_len; }
    }

    /* output capacity: original size + (occ * (new_len - root_len)), bounded
     * below by the original size + 1 for the no-occurrence / shrink case. */
    long delta = (long)new_len - (long)root_len;
    size_t grow = (delta > 0) ? occ * (size_t)delta : 0;
    size_t out_cap = text_len + grow + 1;
    char *out = malloc(out_cap);
    if (!out) { free(host_root); return NULL; }

    /* single-pass replace: emit new_store wherever text matches host_root. */
    size_t oi = 0;
    const char *s = text;
    while (*s) {
        if (!strncmp(s, host_root, root_len)) {
            memcpy(out + oi, new_store, new_len);
            oi += new_len;
            s += root_len;
        } else {
            out[oi++] = *s++;
        }
    }
    out[oi] = '\0';

    free(host_root);
    return out;
}
