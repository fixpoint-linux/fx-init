#!/bin/sh
# Build fx-activate (U-B). Links dhall-c + fxstore(full) + datalog-dafsa + dafsa.
cd "$(dirname "$0")/.."
mkdir -p build-tmp
ENGINE="vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
DAFSA="vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c vendor/dafsa/dafsa_view_rank.c"
FXSTORE="vendor/fxstore/packageset.c vendor/fxstore/derivation.c vendor/fxstore/closure.c vendor/fxstore/store.c vendor/fxstore/build.c"
DHALLC="vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c vendor/dhall-c/src/http.c"
INC="-I src -I vendor/fxstore -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"
DEF='-DFXSTORE_STAGE3_PATH="/fx/store/share/stage3"'
echo "[fx-activate] compiling..."
cosmocc -std=c11 -O2 -g -Wall -Wextra -ffunction-sections -fdata-sections -Wl,--gc-sections $DEF $INC -o build-tmp/fx-activate src/config.c src/fx-activate.c $FXSTORE $ENGINE $DAFSA $DHALLC 2>build-tmp/fx-activate.err
echo "[fx-activate] exit=$?  (errors in build-tmp/fx-activate.err)"
