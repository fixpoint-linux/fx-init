#!/bin/sh
# tests/build_log.sh — build the fx_log unit test (log_test).
# Links log_test.c + src/fx_log.c + datalog-dafsa engine + dafsa (NO fxstore, NO dhall-c).
set -e
cd /workspace/fx-init
mkdir -p build-tmp
ENGINE="vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
DAFSA="vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c vendor/dafsa/dafsa_view_rank.c"
INC="-I src -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa"
cosmocc -std=c11 -O2 -g -Wall -Wextra $INC -o build-tmp/log_test \
    tests/log_test.c src/fx_log.c $ENGINE $DAFSA
echo "log_test built"
