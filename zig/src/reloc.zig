// reloc.zig — faithful Zig port of src/fx_reloc.c: the buildfile store-root
// relocation rewrite (see src/fx_reloc.h).  Pure string transform: find the
// `let GEN = "..."` binding, derive the activation-time host store root
// (everything up to the path's last '/'), then replace EVERY occurrence of
// that root with the new store.  NULL on malformed input (no marker,
// unterminated literal, GEN with no '/'), verbatim copy when the root is
// "/" (already /-absolute — nothing sensible to rewrite).
//
// Contract (pinned by tests/reloctest.c):
//   - the host root is replaced everywhere it appears (single pass, no
//     overlap: the scanner advances past a match by root_len);
//   - absolute `to` paths (/etc, /bin, /run) are untouched;
//   - idempotent when host root == new root;
//   - \" and \\ escapes inside the GEN literal are skipped when locating the
//     closing quote (a `"` after a backslash does not close it).
const std = @import("std");

/// C `strstr(haystack, needle)` on non-NUL slices: first index of `needle`
/// in `haystack`, or null.  (The C inputs are NUL-terminated C strings; all
/// corpus inputs here are ordinary text without embedded NULs.)
fn strstr(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Port of dhall_str_end: locate the closing quote of a Dhall "..." string
/// literal starting just AFTER the opening `"`.  Handles \" and \\ escapes
/// (an escaped char is skipped together with its backslash).  Returns the
/// index of the closing `"`, or null if the literal is unterminated (the
/// scan runs into the NUL terminator).
fn dhall_str_end(text: []const u8, open: usize) ?usize {
    var q = open;
    while (q < text.len) { // text[q] == '\0' ends the loop in the C
        if (text[q] == '\\' and q + 1 < text.len) {
            q += 2; // escaped char: skip both (C: if (*q=='\\' && q[1]) q+=2)
        } else if (text[q] == '"') {
            return q; // closing quote
        } else {
            q += 1;
        }
    }
    return null;
}

/// Port of fx_reloc_rewrite_buildfile.  Returns an allocated NUL-terminated
/// rewritten buildfile (caller frees), or null on failure exactly where the
/// C returns NULL: !text || !new_store cannot happen here (slices are
/// non-null), no `let GEN = "` marker, unterminated GEN literal, GEN with
/// no '/', or OOM.  The host root "/" (root_len == 0) yields a verbatim
/// copy so the caller can still exec dhake on it.
pub fn fx_reloc_rewrite_buildfile(
    gpa: std.mem.Allocator,
    text: []const u8,
    new_store: []const u8,
) error{OutOfMemory}!?[:0]u8 {
    // find the `let GEN = "..."` binding and extract the host store root
    const marker = "let GEN = \"";
    const gen = strstr(text, marker) orelse return null; // not our buildfile shape
    const path_start = gen + marker.len; // just after the opening "

    const path_end = dhall_str_end(text, path_start) orelse return null; // unterminated literal

    // host store root = GEN path up to (but not including) its last '/'.
    var last_slash: ?usize = null;
    var p = path_start;
    while (p < path_end) : (p += 1) {
        if (text[p] == '/') last_slash = p;
    }
    const slash = last_slash orelse return null; // GEN has no '/' — no root to rewrite

    const root_len = slash - path_start;
    const new_len = new_store.len;

    // host root "/" => GEN already /-absolute; nothing sensible to rewrite,
    // return a verbatim copy so the caller can still exec dhake on it.
    if (root_len == 0) {
        const copy = gpa.dupeZ(u8, text) catch return error.OutOfMemory;
        return @as(?[:0]u8, copy);
    }

    const host_root = text[path_start..][0..root_len];

    // count occurrences for output sizing (single pass, no overlap: we always
    // advance past a match by root_len, and host_root cannot overlap itself
    // because replacement is a separate emit phase over the original text).
    var occ: usize = 0;
    {
        var cs: usize = 0;
        while (strstr(text[cs..], host_root)) |at| {
            cs += at + root_len;
            occ += 1;
        }
    }

    // output capacity: original size + (occ * (new_len - root_len)).  Unlike
    // the C (which only grows its buffer and writes oi bytes), size it
    // exactly in BOTH directions so the returned slice can be freed as-is;
    // the emitted content is identical.
    const cap = if (new_len > root_len)
        text.len + occ * (new_len - root_len)
    else if (new_len < root_len)
        text.len - occ * (root_len - new_len)
    else
        text.len;

    var out = try gpa.allocSentinel(u8, cap, 0);
    errdefer gpa.free(out);

    // single-pass replace: emit new_store wherever text matches host_root.
    var oi: usize = 0;
    var s: usize = 0;
    while (s < text.len) {
        if (std.mem.startsWith(u8, text[s..], host_root)) {
            @memcpy(out[oi..][0..new_len], new_store);
            oi += new_len;
            s += root_len;
        } else {
            out[oi] = text[s];
            oi += 1;
            s += 1;
        }
    }
    out[oi] = 0;
    // exact-size contract: oi == cap by construction (grow, equal, shrink)
    return out;
}

// ─── tests (pin the reloctest.c contract) ─────────────────────────────────

test "reloc: basic relocation" {
    const a = std.testing.allocator;
    const bf =
        "let Action =\n" ++
        "      < Copy : { from : Text, to : Text } | Symlink : { from : Text, to : Text } >\n" ++
        "let Target = { deps : List Text, phony : Bool, recipe : List Action }\n" ++
        "let GEN = \"/tmp/fxact123/store/abc123-system-generation\"\n" ++
        "in  { default = \"rootfs\"\n" ++
        "    , targets =\n" ++
        "        [ { mapKey = \"dirs\"\n" ++
        "          , mapValue = { deps = [] : List Text, phony = True\n" ++
        "              , recipe = [ < Symlink = { from = \"/tmp/fxact123/store/deadbeef-fx-init\"\n" ++
        "                                         , to = \"/bin/init\" } > ] } }\n" ++
        "        , { mapKey = \"etc\"\n" ++
        "          , mapValue = { deps = [\"dirs\"], phony = True\n" ++
        "              , recipe = [ < Copy = { from = GEN ++ \"/etc/hostname\"\n" ++
        "                                     , to = \"/etc/hostname\" } > ] } }\n" ++
        "        , { mapKey = \"rootfs\"\n" ++
        "          , mapValue = { deps = [\"etc\",\"dirs\"], phony = True\n" ++
        "              , recipe = [] : List Action } }\n" ++
        "        ]\n" ++
        "    }\n";
    const out = (try fx_reloc_rewrite_buildfile(a, bf, "/fx/store")).?;
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "let GEN = \"/fx/store/abc123-system-generation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/fx/store/deadbeef-fx-init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/fxact123/store") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "to = \"/etc/hostname\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "to = \"/bin/init\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "GEN ++ \"/etc/hostname\"") != null);
}

test "reloc: idempotent + malformed + escapes + root-slash + multi" {
    const a = std.testing.allocator;
    const bf = "let GEN = \"/tmp/s/x-system-generation\"\n" ++
        "from = \"/tmp/s/a-fx-init\" from = \"/tmp/s/b-fxctl\"\n";
    // idempotent: host root == new root
    {
        const out = (try fx_reloc_rewrite_buildfile(a, bf, "/tmp/s")).?;
        defer a.free(out);
        try std.testing.expectEqualStrings(bf, out);
    }
    // malformed: no `let GEN` => null; GEN with no '/' => null; unterminated => null
    try std.testing.expect((try fx_reloc_rewrite_buildfile(a, "let Action = ...\nlet Target = ...\n", "/fx/store")) == null);
    try std.testing.expect((try fx_reloc_rewrite_buildfile(a, "let GEN = \"nogen\"\n", "/fx/store")) == null);
    try std.testing.expect((try fx_reloc_rewrite_buildfile(a, "let GEN = \"/tmp/store/abc\n", "/fx/store")) == null);
    // escaped quote inside the GEN path handled; root includes the literal backslash
    {
        const bfq = "let GEN = \"/tmp/sto\\\"re/abc-system-generation\"\n";
        const out = (try fx_reloc_rewrite_buildfile(a, bfq, "/fx/store")).?;
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "/fx/store/abc-system-generation") != null);
    }
    // host root "/" => verbatim copy
    {
        const bfs = "let GEN = \"/abc-system-generation\"\n" ++
            "< Symlink = { from = \"/def-fx-init\", to = \"/bin/init\" } >\n";
        const out = (try fx_reloc_rewrite_buildfile(a, bfs, "/fx/store")).?;
        defer a.free(out);
        try std.testing.expectEqualStrings(bfs, out);
    }
    // multiple occurrences all rewritten
    {
        const out = (try fx_reloc_rewrite_buildfile(a, bf, "/fx/store")).?;
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "/tmp/s") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/fx/store/x-system-generation") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/fx/store/a-fx-init") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/fx/store/b-fxctl") != null);
    }
}
