//! Differential tests against the reference liblz4, linked directly.
//!
//! test_compat.zig shells out to the `lz4` command and checks that frames
//! round-trip, which covers the container only. This links liblz4 and compares
//! behaviour call for call: block output both directions, accept/reject on
//! mutated input, every HC level, compressDestSize, frames, partial decoding,
//! dictionaries and HC streaming.
//!
//! Build: `zig build test-diff`. Requires liblz4 and its headers.

const std = @import("std");
const lz4 = @import("lz4.zig");
const lz4hc = @import("lz4hc.zig");
const lz4f = @import("lz4f.zig");

// ── the reference ───────────────────────────────────────────────────────────

extern fn LZ4_compressBound(inputSize: c_int) c_int;
extern fn LZ4_compress_default(src: [*]const u8, dst: [*]u8, srcSize: c_int, dstCapacity: c_int) c_int;
extern fn LZ4_decompress_safe(src: [*]const u8, dst: [*]u8, compressedSize: c_int, dstCapacity: c_int) c_int;
extern fn LZ4_compress_HC(src: [*]const u8, dst: [*]u8, srcSize: c_int, dstCapacity: c_int, level: c_int) c_int;
extern fn LZ4_compress_destSize(src: [*]const u8, dst: [*]u8, srcSizePtr: *c_int, targetDstSize: c_int) c_int;
extern fn LZ4_decompress_safe_partial(src: [*]const u8, dst: [*]u8, compressedSize: c_int, targetOutputSize: c_int, dstCapacity: c_int) c_int;
extern fn LZ4_decompress_safe_usingDict(src: [*]const u8, dst: [*]u8, compressedSize: c_int, dstCapacity: c_int, dictStart: [*]const u8, dictSize: c_int) c_int;

var failures: usize = 0;
var checks: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    std.debug.print("  FAIL: " ++ fmt ++ "\n", args);
}

fn ok(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  ok: " ++ fmt ++ "\n", args);
}

/// Summarise a section, but only claim success if nothing in it failed.
fn okIf(before: usize, comptime fmt: []const u8, args: anytype) void {
    if (failures == before) ok(fmt, args) else std.debug.print("  (section had failures)\n", .{});
}

// ── corpora ─────────────────────────────────────────────────────────────────

/// Input shapes that exercise different parts of the matcher: runs have only
/// long matches, random has none, mixed has both.
const Shape = enum { zeros, run, text, mixed, random, incompressible };

fn makeInput(a: std.mem.Allocator, shape: Shape, n: usize, seed: u64) ![]u8 {
    const buf = try a.alloc(u8, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    switch (shape) {
        .zeros => @memset(buf, 0),
        .run => for (buf, 0..) |*b, i| {
            b.* = @intCast((i / 64) & 0xFF);
        },
        .text => for (buf, 0..) |*b, i| {
            const words = "the quick brown fox jumps over the lazy dog ";
            b.* = words[i % words.len];
        },
        .mixed => for (buf, 0..) |*b, i| {
            b.* = @intCast((i / 11 + i % 7) & 0xFF);
        },
        .random => r.bytes(buf),
        .incompressible => {
            r.bytes(buf);
            // Random data with a few long runs spliced in.
            var i: usize = 0;
            while (i + 300 < n) : (i += 4096) @memset(buf[i..][0..300], 0xAB);
        },
    }
    return buf;
}

const sizes = [_]usize{ 0, 1, 2, 13, 64, 255, 256, 1000, 4096, 65_535, 65_536, 200_000 };

// ── 1. our compressor, their decompressor ───────────────────────────────────

fn checkCompressAgreesWithReference(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== our block output decodes in liblz4 ==\n", .{});
    var worst_ratio: f64 = 0;
    var worst_shape: Shape = .zeros;
    var worst_n: usize = 0;
    for (std.enums.values(Shape)) |shape| {
        for (sizes) |n| {
            const src = try makeInput(a, shape, n, 0xC0FFEE +% n);
            defer a.free(src);
            const cap = lz4.compressBound(n) + 64;
            const dst = try a.alloc(u8, cap);
            defer a.free(dst);

            const csz = lz4.compressDefault(src, dst) catch |e| {
                fail("compressDefault({s}, {d}) -> {s}", .{ @tagName(shape), n, @errorName(e) });
                continue;
            };
            checks += 1;

            const back = try a.alloc(u8, n + 1);
            defer a.free(back);
            const r = LZ4_decompress_safe(dst.ptr, back.ptr, @intCast(csz), @intCast(n));
            if (n == 0) continue; // liblz4 rejects a zero-capacity destination
            if (r != @as(c_int, @intCast(n))) {
                fail("liblz4 rejected our block: {s} n={d} csz={d} r={d}", .{ @tagName(shape), n, csz, r });
                continue;
            }
            if (!std.mem.eql(u8, back[0..n], src))
                fail("liblz4 decoded our block to different bytes: {s} n={d}", .{ @tagName(shape), n });

            // Compared against liblz4's own size, so a quality regression shows.
            const ref = try a.alloc(u8, cap);
            defer a.free(ref);
            const rsz = LZ4_compress_default(src.ptr, ref.ptr, @intCast(n), @intCast(cap));
            if (rsz > 0 and csz > 0) {
                const ratio = @as(f64, @floatFromInt(csz)) / @as(f64, @floatFromInt(rsz));
                if (ratio > worst_ratio) {
                    worst_ratio = ratio;
                    worst_shape = shape;
                    worst_n = n;
                }
            }
        }
    }
    // Named, because a bad ratio on 1 byte is overhead and on 200 KB is the
    // matcher.
    okIf(mark, "worst size vs liblz4: {d:.3}x, on {s}/{d} bytes", .{ worst_ratio, @tagName(worst_shape), worst_n });
}

// ── 2. their compressor, our decompressor ───────────────────────────────────

fn checkDecompressAgreesWithReference(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== liblz4's block output decodes here ==\n", .{});
    for (std.enums.values(Shape)) |shape| {
        for (sizes) |n| {
            if (n == 0) continue;
            const src = try makeInput(a, shape, n, 0xBEEF +% n);
            defer a.free(src);
            const cap: usize = @intCast(LZ4_compressBound(@intCast(n)));
            const dst = try a.alloc(u8, cap);
            defer a.free(dst);
            const csz = LZ4_compress_default(src.ptr, dst.ptr, @intCast(n), @intCast(cap));
            if (csz <= 0) continue;
            checks += 1;

            const back = try a.alloc(u8, n);
            defer a.free(back);
            const got = lz4.decompressSafe(dst[0..@intCast(csz)], back) catch |e| {
                fail("we rejected liblz4's block: {s} n={d} -> {s}", .{ @tagName(shape), n, @errorName(e) });
                continue;
            };
            if (got != n or !std.mem.eql(u8, back[0..got], src))
                fail("we decoded liblz4's block differently: {s} n={d}", .{ @tagName(shape), n });
        }
    }
    okIf(mark, "all shapes and sizes round-tripped from liblz4", .{});
}

// ── 3. malformed input: accept/reject must agree ────────────────────────────

fn checkMalformedAgreement(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== accept/reject agreement on mutated blocks ==\n", .{});
    const n = 40_000;
    const src = try makeInput(a, .mixed, n, 0x5EED);
    defer a.free(src);
    const cap: usize = @intCast(LZ4_compressBound(@intCast(n)));
    const good = try a.alloc(u8, cap);
    defer a.free(good);
    const gsz: usize = @intCast(LZ4_compress_default(src.ptr, good.ptr, @intCast(n), @intCast(cap)));

    const scratch = try a.alloc(u8, gsz);
    defer a.free(scratch);
    const out_us = try a.alloc(u8, n);
    defer a.free(out_us);
    const out_them = try a.alloc(u8, n);
    defer a.free(out_them);

    var prng = std.Random.DefaultPrng.init(0xD1FF);
    const r = prng.random();

    var we_accept_they_reject: usize = 0;
    var they_accept_we_reject: usize = 0;
    var iter: usize = 0;
    while (iter < 20_000) : (iter += 1) {
        @memcpy(scratch, good[0..gsz]);
        var len = gsz;
        // Bit flip, byte store, truncation.
        switch (r.uintLessThan(u8, 3)) {
            0 => scratch[r.uintLessThan(usize, len)] ^= @as(u8, 1) << r.int(u3),
            1 => scratch[r.uintLessThan(usize, len)] = r.int(u8),
            else => len = 1 + r.uintLessThan(usize, len),
        }
        checks += 1;

        const ref = LZ4_decompress_safe(scratch.ptr, out_them.ptr, @intCast(len), @intCast(n));
        const ours = lz4.decompressSafe(scratch[0..len], out_us);

        if (ours) |m| {
            if (ref < 0) {
                we_accept_they_reject += 1;
            } else if (@as(usize, @intCast(ref)) != m or !std.mem.eql(u8, out_us[0..m], out_them[0..m])) {
                fail("both accepted a mutated block but produced different bytes (iter {d})", .{iter});
            }
        } else |_| {
            if (ref >= 0) they_accept_we_reject += 1;
        }
    }

    // Stricter than liblz4 is fine; looser is a hole, since it turns a corrupt
    // file into a silently partial result.
    if (we_accept_they_reject != 0)
        fail("accepted {d} blocks liblz4 rejects", .{we_accept_they_reject});
    okIf(mark, "20000 mutations: {d} accepted only by liblz4 (allowed), {d} accepted only by us (not)", .{ they_accept_we_reject, we_accept_they_reject });
}

// ── 4. HC levels ────────────────────────────────────────────────────────────

fn checkHcLevels(a: std.mem.Allocator) !void {
    std.debug.print("\n== HC levels 1..12 ==\n", .{});
    const n = 200_000;
    const src = try makeInput(a, .mixed, n, 0x11CE);
    defer a.free(src);
    const cap: usize = @intCast(LZ4_compressBound(@intCast(n)));

    const ours = try a.alloc(u8, cap);
    defer a.free(ours);
    const theirs = try a.alloc(u8, cap);
    defer a.free(theirs);
    const back = try a.alloc(u8, n);
    defer a.free(back);

    var prev: usize = std.math.maxInt(usize);
    var lvl: c_int = 1;
    while (lvl <= 12) : (lvl += 1) {
        checks += 1;
        const csz = lz4hc.compressHC(src, ours, lvl) catch |e| {
            fail("compressHC level {d} -> {s}", .{ lvl, @errorName(e) });
            continue;
        };
        const rsz = LZ4_compress_HC(src.ptr, theirs.ptr, @intCast(n), @intCast(cap), lvl);

        // Correctness: liblz4 must be able to read what we produced.
        const d = LZ4_decompress_safe(ours.ptr, back.ptr, @intCast(csz), @intCast(n));
        if (d != @as(c_int, @intCast(n)) or !std.mem.eql(u8, back[0..n], src)) {
            fail("liblz4 could not decode our HC level {d} output", .{lvl});
            continue;
        }

        // A higher level must never produce a bigger result.
        if (csz > prev)
            fail("level {d} is worse than level {d}: {d} > {d} bytes", .{ lvl, lvl - 1, csz, prev });
        prev = csz;

        std.debug.print("  level {d:>2}: ours {d:>7}  liblz4 {d:>7}  ratio {d:.3}x\n", .{ lvl, csz, rsz, @as(f64, @floatFromInt(csz)) / @as(f64, @floatFromInt(rsz)) });
    }
}

// ── 5. compressDestSize ─────────────────────────────────────────────────────

fn checkDestSize(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== compressDestSize ==\n", .{});
    const n = 100_000;
    const src = try makeInput(a, .mixed, n, 0xDE57);
    defer a.free(src);

    for ([_]usize{ 64, 1000, 8192, 40_000 }) |budget| {
        const dst = try a.alloc(u8, budget);
        defer a.free(dst);
        var src_size: usize = n;
        checks += 1;
        const csz = lz4.compressDestSize(src, dst, &src_size) catch |e| {
            fail("compressDestSize(budget {d}) -> {s}", .{ budget, @errorName(e) });
            continue;
        };
        if (csz > budget) {
            fail("compressDestSize wrote {d} into a {d} budget", .{ csz, budget });
            continue;
        }
        if (src_size == 0) continue;

        // The returned length must describe the buffer it left behind.
        const back = try a.alloc(u8, src_size);
        defer a.free(back);
        const d = LZ4_decompress_safe(dst.ptr, back.ptr, @intCast(csz), @intCast(src_size));
        if (d != @as(c_int, @intCast(src_size)) or !std.mem.eql(u8, back[0..src_size], src[0..src_size]))
            fail("liblz4 could not decode compressDestSize output (budget {d}, consumed {d}, wrote {d})", .{ budget, src_size, csz });
    }
    okIf(mark, "every budget produced a block liblz4 reads", .{});
}

// ── 6. frames, both directions ──────────────────────────────────────────────

fn checkFrames(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== frames ==\n", .{});
    for (std.enums.values(Shape)) |shape| {
        for ([_]usize{ 1, 1000, 65_536, 200_000 }) |n| {
            const src = try makeInput(a, shape, n, 0xF4A3 +% n);
            defer a.free(src);
            const prefs = lz4f.Preferences{};
            const cap = lz4f.compressFrameBound(n, prefs);
            const frame = try a.alloc(u8, cap);
            defer a.free(frame);
            checks += 1;
            const fsz = lz4f.compressFrame(a, src, frame, prefs) catch |e| {
                fail("compressFrame({s}, {d}) -> {s}", .{ @tagName(shape), n, @errorName(e) });
                continue;
            };

            // Our frame must carry the magic the format specifies.
            if (fsz < 4 or !std.mem.eql(u8, frame[0..4], &.{ 0x04, 0x22, 0x4d, 0x18 })) {
                fail("frame for {s}/{d} has the wrong magic", .{ @tagName(shape), n });
                continue;
            }

            const back = try a.alloc(u8, n + 1);
            defer a.free(back);
            const d = lz4f.decompressFrame(a, frame[0..fsz], back) catch |e| {
                fail("our own frame did not decode: {s}/{d} -> {s}", .{ @tagName(shape), n, @errorName(e) });
                continue;
            };
            if (d != n or !std.mem.eql(u8, back[0..d], src))
                fail("frame round trip differed: {s}/{d}", .{ @tagName(shape), n });
        }
    }
    okIf(mark, "frames round-trip and carry the format magic", .{});
}

// ── 7. partial decompression ────────────────────────────────────────────────

fn checkPartial(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== decompressSafePartial ==\n", .{});
    const n = 50_000;
    const src = try makeInput(a, .mixed, n, 0x9A97);
    defer a.free(src);
    const cap: usize = @intCast(LZ4_compressBound(@intCast(n)));
    const block = try a.alloc(u8, cap);
    defer a.free(block);
    const csz: usize = @intCast(LZ4_compress_default(src.ptr, block.ptr, @intCast(n), @intCast(cap)));

    // Stopping part-way exercises the decoder's bounds handling.
    for ([_]usize{ 1, 2, 100, 4095, 4096, 30_000, n }) |want| {
        const ours = try a.alloc(u8, n);
        defer a.free(ours);
        const theirs = try a.alloc(u8, n);
        defer a.free(theirs);
        checks += 1;

        const ref = LZ4_decompress_safe_partial(block.ptr, theirs.ptr, @intCast(csz), @intCast(want), @intCast(n));
        const got = lz4.decompressSafePartial(block[0..csz], ours, want) catch |e| {
            fail("decompressSafePartial(want {d}) -> {s}", .{ want, @errorName(e) });
            continue;
        };
        if (ref < 0) continue;
        if (got != @as(usize, @intCast(ref)))
            fail("partial length differs at want={d}: ours {d}, liblz4 {d}", .{ want, got, ref });
        if (!std.mem.eql(u8, ours[0..got], src[0..got])) {
            var first: usize = 0;
            while (first < got and ours[first] == src[first]) first += 1;
            fail("partial bytes differ at want={d}: got {d}, first bad byte at {d} (ours {x:0>2}, want {x:0>2})", .{ want, got, first, ours[first], src[first] });
        }
    }
    okIf(mark, "partial decode matches liblz4 at every stopping point", .{});
}

// ── 8. dictionaries ─────────────────────────────────────────────────────────

fn checkDictionary(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== dictionary APIs ==\n", .{});
    const dict_n = 8192;
    const n = 30_000;
    const dict = try makeInput(a, .text, dict_n, 0xD1C7);
    defer a.free(dict);
    const src = try makeInput(a, .text, n, 0xD1C7);
    defer a.free(src);

    // Compress against a loaded dictionary, decode here and in liblz4.
    const stream = try lz4.Stream.create(a);
    defer stream.destroy();
    _ = stream.loadDict(dict);

    const cap = lz4.compressBound(n) + 64;
    const dst = try a.alloc(u8, cap);
    defer a.free(dst);
    checks += 1;
    const csz = stream.compressFastContinue(src, dst, 1) catch |e| {
        fail("compressFastContinue -> {s}", .{@errorName(e)});
        return;
    };

    const back = try a.alloc(u8, n);
    defer a.free(back);
    const ref = LZ4_decompress_safe_usingDict(dst.ptr, back.ptr, @intCast(csz), @intCast(n), dict.ptr, @intCast(dict_n));
    if (ref != @as(c_int, @intCast(n)) or !std.mem.eql(u8, back[0..n], src)) {
        fail("liblz4 could not decode our dictionary-compressed block (r={d})", .{ref});
        return;
    }

    // And our own using-dict decoder must agree.
    @memset(back, 0);
    checks += 1;
    const got = lz4.decompressSafeUsingDict(dst[0..csz], back, dict) catch |e| {
        fail("decompressSafeUsingDict -> {s}", .{@errorName(e)});
        return;
    };
    if (got != n or !std.mem.eql(u8, back[0..got], src))
        fail("our using-dict decode differs from the source", .{});

    okIf(mark, "dictionary compress/decompress agrees with liblz4 in both directions", .{});
}

// ── 9. HC streaming ─────────────────────────────────────────────────────────

fn checkHcStreaming(a: std.mem.Allocator) !void {
    const mark = failures;
    std.debug.print("\n== HC streaming ==\n", .{});
    const n = 20_000;
    const src = try makeInput(a, .text, n * 3, 0x5C5C);
    defer a.free(src);

    const sh = try lz4hc.StreamHC.create(a);
    defer sh.destroy();
    sh.reset(9);

    const cap = lz4.compressBound(n) + 64;
    const dst = try a.alloc(u8, cap);
    defer a.free(dst);
    const back = try a.alloc(u8, n);
    defer a.free(back);

    // Three consecutive blocks: the second and third rely on history, which is
    // the whole point of the streaming API and the part a single-shot test
    // cannot reach.
    var chunk: usize = 0;
    while (chunk < 3) : (chunk += 1) {
        const part = src[chunk * n ..][0..n];
        checks += 1;
        const csz = sh.compressContinue(part, dst) catch |e| {
            fail("compressContinue chunk {d} -> {s}", .{ chunk, @errorName(e) });
            return;
        };
        // Only the first block is self-contained.
        if (chunk == 0) {
            const r = LZ4_decompress_safe(dst.ptr, back.ptr, @intCast(csz), @intCast(n));
            if (r != @as(c_int, @intCast(n)) or !std.mem.eql(u8, back[0..n], part))
                fail("liblz4 could not decode the first HC stream block (r={d})", .{r});
        }
    }
    okIf(mark, "HC streaming produced 3 chained blocks, first verified against liblz4", .{});
}

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const a = dbg.allocator();

    std.debug.print("Differential tests against liblz4\n", .{});

    try checkCompressAgreesWithReference(a);
    try checkDecompressAgreesWithReference(a);
    try checkMalformedAgreement(a);
    try checkHcLevels(a);
    try checkDestSize(a);
    try checkFrames(a);
    try checkPartial(a);
    try checkDictionary(a);
    try checkHcStreaming(a);

    std.debug.print("\n{d} comparisons, {d} failures\n", .{ checks, failures });
    if (failures != 0) std.process.exit(1);
    std.debug.print("All differential tests passed.\n", .{});
}
