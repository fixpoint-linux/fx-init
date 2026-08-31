// fxstore.zig — facade over the fxstore Zig port (sibling ../fxstore/zig/src),
// re-exporting the surface activate.zig + init.zig need so they import ONE
// module with a single consistent `DlDb` opaque type.
//
// The fxstore store core (packageset/derivation/closure/store/build.c) was
// ported to Zig in the sibling fxstore repo (fxstore/zig/src/{packageset,
// derivation,closure,store,build}.zig) and verified byte-identical against its
// C oracle.  fx-init reuses those modules instead of compiling the vendored C
// (vendor/fxstore/*.c + vendor/dhall-c/src/*.c) — this facade is the seam.
// The dl_* externs declared by closure.zig/store.zig (and re-exported here)
// resolve against the Zig-built libdatalog.so linked into activate_mod/init_mod
// by build.zig's linkDatalog.
const std = @import("std");
const dhall = @import("dhall");

pub const packageset = @import("packageset");
pub const derivation = @import("derivation");
pub const closure = @import("closure");
pub const store = @import("store");

// ─── types ──────────────────────────────────────────────────────────────────

pub const Package = packageset.Package;
pub const PackageSet = packageset.PackageSet;
pub const Action = packageset.Action;
pub const Src = packageset.Src;
pub const ActionKind = packageset.ActionKind;
pub const SrcKind = packageset.SrcKind;
pub const Store = store.Store;
pub const DlDb = closure.DlDb;
pub const DlIter = closure.DlIter;

// ─── dl_* externs (closure.zig + store.zig declare them against DlDb/DlIter) ──

pub const dl_open = closure.dl_open;
pub const dl_close = closure.dl_close;
pub const dl_declare_relation = closure.dl_declare_relation;
pub const dl_add_fact = closure.dl_add_fact;
pub const dl_delete_fact = closure.dl_delete_fact;
pub const dl_count = closure.dl_count;
pub const dl_load_rules = closure.dl_load_rules;
pub const dl_compile = closure.dl_compile;
pub const dl_publish_snapshot = closure.dl_publish_snapshot;
pub const dl_query = closure.dl_query;
pub const dl_intern_str = closure.dl_intern_str;
pub const dl_intern_str_of = closure.dl_intern_str_of;
pub const dl_iter_open = closure.dl_iter_open;
pub const dl_iter_arity = closure.dl_iter_arity;
pub const dl_iter_next = closure.dl_iter_next;
pub const dl_iter_close = closure.dl_iter_close;
pub const dl_lookup = store.dl_lookup;
pub const dl_txn_begin = store.dl_txn_begin;
pub const dl_txn_add_fact = store.dl_txn_add_fact;
pub const dl_txn_delete_fact = store.dl_txn_delete_fact;
pub const dl_txn_commit = store.dl_txn_commit;
pub const dl_txn_rollback = store.dl_txn_rollback;
pub const dl_snapshot_versions = store.dl_snapshot_versions;
pub const dl_query_version = store.dl_query_version;
pub const dl_set_snapshot_retain = store.dl_set_snapshot_retain;

// ─── functions ──────────────────────────────────────────────────────────────

pub const fx_packageset_load = packageset.fx_packageset_load;
pub const fx_content_hash_dir = derivation.fx_content_hash_dir;
pub const fx_derivation_hash_ex = derivation.fx_derivation_hash_ex;
pub const fx_store_path_of = derivation.fx_store_path_of;
pub const fx_closure_compute = closure.fx_closure_compute;
pub const fx_closure_names = closure.fx_closure_names;
pub const free_names = closure.free_names;
pub const fx_topo_order = closure.fx_topo_order;
pub const free_order = closure.free_order;
pub const fx_store_open = store.fx_store_open;
pub const fx_store_close = store.fx_store_close;
pub const fx_store_db = store.fx_store_db;
pub const fx_store_publish = store.fx_store_publish;
pub const fx_store_current_version = store.fx_store_current_version;
pub const fx_store_rollback = store.fx_store_rollback;

/// SHA-256 (FIPS 180-4), the very implementation the C fxstore linked — used
/// for the generation-hash serialization (activate.zig).
pub const sha256_hex = dhall.sha256.sha256_hex;
