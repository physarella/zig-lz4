# zig-lz4

A pure Zig implementation of LZ4 compression, following the C reference implementation by Yann Collet.

**Not yet a complete port.** The block format and its streaming API are complete; the frame format has only its one-shot calls, and the HC compressor is missing three entry points and does not do lazy matching. See [What is not implemented](#what-is-not-implemented).

## What is LZ4?

LZ4 is a fast lossless compression algorithm focused on speed. It's widely used in systems where you need compression but can't afford the CPU overhead of heavier algorithms like gzip or zstd.

## Features

- Block compression - The basic LZ4 algorithm for compressing individual blocks
- HC mode - High compression variant that trades speed for better compression ratios
- Frame format - The standard LZ4 frame format, one-shot compress and decompress
- Streaming - Block and HC streaming, with dictionaries
- Dictionaries - Use external dictionaries for better compression of small blocks

All code is pure Zig with no C dependencies. Output is interoperable with the
standard `lz4` tool in both directions, and `zig build test-diff` compares
behaviour against liblz4 directly.

## What is not implemented

Measured against liblz4 1.10 with `zig build test-diff`.

**The LZ4F streaming API is absent.** `lz4frame.h` exposes roughly fifteen
functions; only `LZ4F_compressFrame`, `LZ4F_compressFrameBound`,
`LZ4F_headerSize` and `LZ4F_isError` have counterparts here. Missing:

    LZ4F_createCompressionContext    LZ4F_createDecompressionContext
    LZ4F_compressBegin               LZ4F_decompress
    LZ4F_compressBound               LZ4F_getFrameInfo
    LZ4F_compressUpdate              LZ4F_resetDecompressionContext
    LZ4F_flush                       LZ4F_freeCompressionContext
    LZ4F_compressEnd                 LZ4F_freeDecompressionContext

A caller that has to decode a frame arriving in pieces cannot do it with this
library; there is no context to feed.

**The HC compressor does not do lazy matching.** `compressHashChain` commits to
the first match it finds, where liblz4 searches again at `ip + ml - 2` and
`start2 + ml2 - 3` before deciding. The result is valid and interoperable but
6-14% larger at levels 3-9, and level 3 can be worse than level 2, which
`test-diff` reports as a failure.

**Three lz4hc.h entry points are missing**: `LZ4_compress_HC_continue_destSize`,
`LZ4_favorDecompressionSpeed` (the `favorDecSpeed` field exists but is never
read) and `LZ4_compress_HC_extStateHC_fastReset`.

## Requirements

- Zig 0.16.0 or newer

## Usage

Add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .lz4 = .{
        .url = "https://github.com/jedisct1/zig-lz4/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const lz4 = b.dependency("lz4", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("lz4", lz4.module("lz4"));
```

### Basic compression

```zig
const lz4 = @import("lz4");
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const input = "Hello, World!";

    // Allocate buffer for compressed data
    const max_size = lz4.compressBound(input.len);
    const compressed = try allocator.alloc(u8, max_size);
    defer allocator.free(compressed);

    // Compress
    const compressed_size = try lz4.compressDefault(input, compressed);

    // Decompress
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);

    _ = try lz4.decompressSafe(compressed[0..compressed_size], decompressed);
}
```

### HC (high compression) mode

```zig
const lz4 = @import("lz4");

// Use higher compression level (2-12)
const compressed_size = try lz4.compressHC(
    input,
    compressed,
    lz4.LZ4HC_CLEVEL_DEFAULT, // level 9
);
```

### Frame format

The frame format adds checksums and is what the `lz4` command-line tool uses:

```zig
const lz4 = @import("lz4");

// Compress a whole frame in one shot
const bound = lz4.lz4f.compressFrameBound(input.len, null);
const frame = try allocator.alloc(u8, bound);
defer allocator.free(frame);

const frame_size = try lz4.lz4f.compressFrame(allocator, input, frame, null);

// Decompress it back
const decompressed = try allocator.alloc(u8, input.len);
defer allocator.free(decompressed);

const size = try lz4.lz4f.decompressFrame(allocator, frame[0..frame_size], decompressed);
```

Pass a `lz4.lz4f.Preferences` value instead of `null` to pick the block size,
enable checksums, or use an HC compression level.

## Building and testing

```bash
# Run tests
zig build test

# Run specific test suites
zig build test-lz4hc
zig build test-lz4f
zig build test-compat

# Build the library
zig build
```

The test suite includes compatibility tests against the reference `lz4` tool: frames produced by this library are decompressed with `lz4`, and vice versa, at every compression level. The `test-compat` step needs the `lz4` command-line tool installed.

## Compatibility

This implementation is designed to be wire-compatible with the reference LZ4 library. Files compressed with this library can be decompressed by the standard `lz4` tool and vice versa.
