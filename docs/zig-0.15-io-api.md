# Zig 0.15 I/O API Reference

## Key Changes from Previous Versions

- `std.ArrayList(T)` is now unmanaged (no stored allocator)
- `std.io.getStdOut()` removed
- `std.io.bufferedWriter()` removed
- `File.writer()` returns `File.Writer` struct, not a generic writer

## stdout Pattern

```zig
const std = @import("std");
const fs = std.fs;

pub fn main() !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;  // std.Io.Writer

    try w.print("Hello {s}\n", .{"world"});
    try w.writeAll("raw bytes");
    try w.writeByte('x');
    try w.flush();
}
```

## File.Writer Structure

```zig
pub const Writer = struct {
    file: File,
    err: ?WriteError = null,
    interface: std.Io.Writer,  // <-- use this for print/writeAll
    // ...
};
```

## std.Io.Writer Methods

| Method | Signature | Notes |
|--------|-----------|-------|
| `print` | `fn(*Writer, comptime []const u8, anytype) Error!void` | Formatted output |
| `writeAll` | `fn(*Writer, []const u8) Error!void` | Write all bytes |
| `writeByte` | `fn(*Writer, u8) Error!void` | Single byte |
| `write` | `fn(*Writer, []const u8) Error!usize` | Partial write OK |
| `flush` | `fn(*Writer) Error!void` | Drain buffer |

## No writeByteNTimes - Use Loop

```zig
fn writeByteNTimes(w: *std.Io.Writer, byte: u8, n: usize) !void {
    for (0..n) |_| try w.writeByte(byte);
}
```

## ArrayList Changes

```zig
// Old (pre-0.15):
var list = std.ArrayList(T).init(allocator);
try list.append(item);
list.deinit();

// New (0.15):
var list = std.ArrayList(T){};  // or .empty
try list.append(allocator, item);  // allocator passed to methods
list.deinit(allocator);
```

## ArrayListUnmanaged

Same API as new ArrayList - they're now equivalent.

## File Reading

```zig
const file = try fs.openFileAbsolute(path, .{});
defer file.close();
const content = try file.readToEndAlloc(allocator, max_size);
defer allocator.free(content);
```

## File.Reader (buffered line reading)

```zig
const file = try fs.openFileAbsolute(path, .{});
defer file.close();

var read_buf: [64 * 1024]u8 = undefined;
var file_reader = fs.File.Reader.init(file, &read_buf);
const reader = &file_reader.interface;

while (true) {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterExclusive('\n') catch break;
            continue;
        },
        error.ReadFailed => break,
    } orelse break;
    // process line...
}
```

## Threading with ArenaAllocator

```zig
// Per-thread arena to avoid allocator contention
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();
// allocator.free() is a no-op - arena frees all at once

// Atomic work stealing
var work_index = std.atomic.Value(usize).init(0);
const idx = work_index.fetchAdd(1, .monotonic);
```

## JSON Parsing

```zig
const parsed = try std.json.parseFromSlice(
    std.json.Value,
    allocator,
    json_string,
    .{}
);
defer parsed.deinit();
const obj = parsed.value.object;
```
