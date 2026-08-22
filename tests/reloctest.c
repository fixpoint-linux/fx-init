/* tests/reloctest.c — unit test for the buildfile store-root relocation
 * rewrite (fx_reloc_rewrite_buildfile).
 *
 * fx-activate bakes the host store root into the per-generation dhake buildfile
 * (`let GEN = "<host_store>/..."` + bin Symlink `from = "<host_store>/..."`).
 * fx-init rewrites that root to its own --store before exec'ing dhake so the
 * buildfile resolves wherever the store lives at boot.  This test pins the
 * rewrite contract: the host root is replaced everywhere it appears, the
 * absolute `to` paths (/etc, /bin, /run) are untouched, the rewrite is
 * idempotent when host root == new root, and malformed buildfiles (no `let
 * GEN`, GEN with no '/') are rejected (NULL). */
#include "fx_reloc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

/* a buildfile in the exact byte shape fx-activate emits (artifact-1 template):
 * GEN + a Copy whose `from` is GEN-relative + a bin Symlink whose `from` is a
 * host store path, plus absolute `to` paths. */
static const char *BF =
    "let Action =\n"
    "      < Copy : { from : Text, to : Text } | Symlink : { from : Text, to : Text } >\n"
    "let Target = { deps : List Text, phony : Bool, recipe : List Action }\n"
    "let GEN = \"/tmp/fxact123/store/abc123-system-generation\"\n"
    "in  { default = \"rootfs\"\n"
    "    , targets =\n"
    "        [ { mapKey = \"dirs\"\n"
    "          , mapValue = { deps = [] : List Text, phony = True\n"
    "              , recipe = [ < Symlink = { from = \"/tmp/fxact123/store/deadbeef-fx-init\"\n"
    "                                         , to = \"/bin/init\" } > ] } }\n"
    "        , { mapKey = \"etc\"\n"
    "          , mapValue = { deps = [\"dirs\"], phony = True\n"
    "              , recipe = [ < Copy = { from = GEN ++ \"/etc/hostname\"\n"
    "                                     , to = \"/etc/hostname\" } > ] } }\n"
    "        , { mapKey = \"rootfs\"\n"
    "          , mapValue = { deps = [\"etc\",\"dirs\"], phony = True\n"
    "              , recipe = [] : List Action } }\n"
    "        ]\n"
    "    }\n";

int main(void) {
    /* 1. basic relocation: host /tmp/fxact123/store -> /fx/store */
    {
        char *out = fx_reloc_rewrite_buildfile(BF, "/fx/store");
        CHECK(out != NULL, "basic: returned NULL");
        if (out) {
            CHECK(strstr(out, "let GEN = \"/fx/store/abc123-system-generation\"") != NULL,
                  "basic: GEN host root not rewritten to /fx/store");
            CHECK(strstr(out, "/fx/store/deadbeef-fx-init") != NULL,
                  "basic: bin Symlink from not rewritten to /fx/store");
            CHECK(strstr(out, "/tmp/fxact123/store") == NULL,
                  "basic: host store root still present after rewrite");
            CHECK(strstr(out, "to = \"/etc/hostname\"") != NULL,
                  "basic: absolute to-path /etc/hostname corrupted");
            CHECK(strstr(out, "to = \"/bin/init\"") != NULL,
                  "basic: absolute to-path /bin/init corrupted");
            CHECK(strstr(out, "GEN ++ \"/etc/hostname\"") != NULL,
                  "basic: GEN ++ concatenation corrupted");
            free(out);
        }
    }

    /* 2. idempotent: host root == new root => text unchanged (modulo nothing). */
    {
        char *out = fx_reloc_rewrite_buildfile(BF, "/tmp/fxact123/store");
        CHECK(out != NULL, "idempotent: returned NULL");
        if (out) {
            CHECK(strcmp(out, BF) == 0, "idempotent: text changed when root == new root");
            free(out);
        }
    }

    /* 3. malformed: no `let GEN` binding => NULL */
    {
        char *out = fx_reloc_rewrite_buildfile("let Action = ...\nlet Target = ...\n", "/fx/store");
        CHECK(out == NULL, "malformed: no `let GEN` should return NULL");
    }

    /* 4. GEN with no '/' => NULL (no host root derivable) */
    {
        char *out = fx_reloc_rewrite_buildfile("let GEN = \"nogen\"\n", "/fx/store");
        CHECK(out == NULL, "no-slash: GEN with no '/' should return NULL");
    }

    /* 5. unterminated string literal => NULL */
    {
        char *out = fx_reloc_rewrite_buildfile("let GEN = \"/tmp/store/abc\n", "/fx/store");
        CHECK(out == NULL, "unterminated: should return NULL");
    }

    /* 6. escaped quote inside the GEN path is handled (closing quote found
     *    after the escape, host root still derived correctly). */
    {
        const char *bf = "let GEN = \"/tmp/sto\\\"re/abc-system-generation\"\n";
        char *out = fx_reloc_rewrite_buildfile(bf, "/fx/store");
        CHECK(out != NULL, "escaped-quote: returned NULL");
        if (out) {
            /* host root = everything up to the last '/' before `-system-generation`:
             * /tmp/sto\"re (the backslash is a literal char in the text). */
            CHECK(strstr(out, "/fx/store/abc-system-generation") != NULL,
                  "escaped-quote: GEN not rewritten");
            free(out);
        }
    }

    /* 7. host root "/" (GEN = "/<gen>-system-generation") => verbatim copy. */
    {
        const char *bf = "let GEN = \"/abc-system-generation\"\n"
                         "< Symlink = { from = \"/def-fx-init\", to = \"/bin/init\" } >\n";
        char *out = fx_reloc_rewrite_buildfile(bf, "/fx/store");
        CHECK(out != NULL, "root-slash: returned NULL");
        if (out) {
            CHECK(strcmp(out, bf) == 0, "root-slash: should be a verbatim copy");
            free(out);
        }
    }

    /* 8. multiple occurrences of host root all rewritten. */
    {
        const char *bf = "let GEN = \"/tmp/s/x-system-generation\"\n"
                         "from = \"/tmp/s/a-fx-init\" from = \"/tmp/s/b-fxctl\"\n";
        char *out = fx_reloc_rewrite_buildfile(bf, "/fx/store");
        CHECK(out != NULL, "multi: returned NULL");
        if (out) {
            CHECK(strstr(out, "/tmp/s") == NULL, "multi: a /tmp/s occurrence survived");
            CHECK(strstr(out, "/fx/store/x-system-generation") != NULL, "multi: GEN");
            CHECK(strstr(out, "/fx/store/a-fx-init") != NULL, "multi: a-fx-init");
            CHECK(strstr(out, "/fx/store/b-fxctl") != NULL, "multi: b-fxctl");
            free(out);
        }
    }

    if (fails) { printf("reloctest: %d FAIL\n", fails); return 1; }
    printf("reloctest: PASS\n");
    return 0;
}
