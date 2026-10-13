const std = @import("std");
const fs = std.Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;
var app_io: std.Io = undefined;

// ============================================================================
// Pricing Data
// ============================================================================

const Pricing = struct {
    input_per_million: f64,
    output_per_million: f64,
    cache_create_per_million: f64 = 0.0,
    cache_read_per_million: f64 = 0.0,
};

// Sorted by longest prefix first for matching (LiteLLM pricing)
const pricing_table = [_]struct { prefix: []const u8, pricing: Pricing }{
    // Claude 4.5 series
    .{ .prefix = "claude-opus-4-5", .pricing = .{ .input_per_million = 5.0, .output_per_million = 25.0, .cache_create_per_million = 6.25, .cache_read_per_million = 0.5 } },
    .{ .prefix = "claude-sonnet-4-5", .pricing = .{ .input_per_million = 3.0, .output_per_million = 15.0, .cache_create_per_million = 3.75, .cache_read_per_million = 0.3 } },
    .{ .prefix = "claude-haiku-4-5", .pricing = .{ .input_per_million = 1.0, .output_per_million = 5.0, .cache_create_per_million = 1.25, .cache_read_per_million = 0.1 } },
    // Claude 4 series
    .{ .prefix = "claude-opus-4-1", .pricing = .{ .input_per_million = 15.0, .output_per_million = 75.0, .cache_create_per_million = 18.75, .cache_read_per_million = 1.5 } },
    .{ .prefix = "claude-opus-4", .pricing = .{ .input_per_million = 15.0, .output_per_million = 75.0, .cache_create_per_million = 18.75, .cache_read_per_million = 1.5 } },
    .{ .prefix = "claude-sonnet-4", .pricing = .{ .input_per_million = 3.0, .output_per_million = 15.0, .cache_create_per_million = 3.75, .cache_read_per_million = 0.3 } },
    // Claude 3.5 series
    .{ .prefix = "claude-3-5-sonnet", .pricing = .{ .input_per_million = 3.0, .output_per_million = 15.0, .cache_create_per_million = 3.75, .cache_read_per_million = 0.3 } },
    .{ .prefix = "claude-3-5-haiku", .pricing = .{ .input_per_million = 0.8, .output_per_million = 4.0, .cache_create_per_million = 1.0, .cache_read_per_million = 0.08 } },
    // Claude 3 series
    .{ .prefix = "claude-3-opus", .pricing = .{ .input_per_million = 15.0, .output_per_million = 75.0, .cache_create_per_million = 18.75, .cache_read_per_million = 1.5 } },
    .{ .prefix = "claude-3-sonnet", .pricing = .{ .input_per_million = 3.0, .output_per_million = 15.0, .cache_create_per_million = 3.75, .cache_read_per_million = 0.3 } },
    .{ .prefix = "claude-3-haiku", .pricing = .{ .input_per_million = 0.25, .output_per_million = 1.25, .cache_create_per_million = 0.3, .cache_read_per_million = 0.03 } },
    // Claude 2
    .{ .prefix = "claude-2", .pricing = .{ .input_per_million = 8.0, .output_per_million = 24.0 } },
};

fn findPricing(model: []const u8) ?Pricing {
    var m = model;
    if (mem.startsWith(u8, m, "anthropic/")) m = m[10..];
    if (mem.startsWith(u8, m, "openrouter/")) m = m[11..];
    if (mem.startsWith(u8, m, "openai/")) m = m[7..];
    for (pricing_table) |entry| {
        if (mem.startsWith(u8, m, entry.prefix)) return entry.pricing;
    }
    return null;
}

fn calculateCost(model: []const u8, input: u64, output: u64, cache_creation: u64, cache_read: u64) f64 {
    if (model.len == 0) return 0.0;
    const p = findPricing(model) orelse return 0.0;
    const input_all = input + cache_creation + cache_read;
    return (@as(f64, @floatFromInt(input_all)) / 1e6) * p.input_per_million +
        (@as(f64, @floatFromInt(cache_creation)) / 1e6) * p.cache_create_per_million +
        (@as(f64, @floatFromInt(cache_read)) / 1e6) * p.cache_read_per_million +
        (@as(f64, @floatFromInt(output)) / 1e6) * p.output_per_million;
}

// ============================================================================
// Comptime Formatters - Avoid repeated buffer declarations
// ============================================================================

fn Fmt(comptime buf_count: usize) type {
    return struct {
        bufs: [buf_count][32]u8 = undefined,
        idx: usize = 0,

        const Self = @This();

        fn next(self: *Self) *[32]u8 {
            const buf = &self.bufs[self.idx];
            self.idx = (self.idx + 1) % buf_count;
            return buf;
        }

        pub fn tokens(self: *Self, value: u64) []const u8 {
            const buf = self.next();
            if (value >= 1_000_000_000) {
                return std.fmt.bufPrint(buf, "{d:.1}B", .{@as(f64, @floatFromInt(value)) / 1e9}) catch "?";
            } else if (value >= 1_000_000) {
                return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1e6}) catch "?";
            } else if (value >= 1_000) {
                return std.fmt.bufPrint(buf, "{d:.1}K", .{@as(f64, @floatFromInt(value)) / 1e3}) catch "?";
            }
            return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
        }

        pub fn cost(self: *Self, value: f64) []const u8 {
            const buf = self.next();
            if (value >= 1e6) {
                return std.fmt.bufPrint(buf, "${d:.1}M", .{value / 1e6}) catch "?";
            } else if (value >= 1e3) {
                return std.fmt.bufPrint(buf, "${d:.0}K", .{value / 1e3}) catch "?";
            }
            return std.fmt.bufPrint(buf, "${d:.0}", .{value}) catch "?";
        }

        pub fn yellow(self: *Self, s: []const u8) []const u8 {
            const buf = self.next();
            return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ ANSI.yellow, s, ANSI.reset }) catch s;
        }

        pub fn yellowBold(self: *Self, s: []const u8) []const u8 {
            const buf = self.next();
            return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ ANSI.yellow, ANSI.bold, s, ANSI.reset }) catch s;
        }

        pub fn cyanBold(self: *Self, s: []const u8) []const u8 {
            const buf = self.next();
            return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ ANSI.cyan, ANSI.bold, s, ANSI.reset }) catch s;
        }

        pub fn dim(self: *Self, s: []const u8) []const u8 {
            const buf = self.next();
            return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ ANSI.dim, s, ANSI.reset }) catch s;
        }
    };
}

// ============================================================================
// Data Structures
// ============================================================================

const UsageEvent = struct {
    timestamp: i64,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
    cost_usd: f64,
    session_id: []const u8,
    project: []const u8,
};

const Totals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cost_usd: f64 = 0.0,

    fn add(self: *Totals, ev: UsageEvent) void {
        self.input_tokens += ev.input_tokens;
        self.output_tokens += ev.output_tokens;
        self.cache_creation_tokens += ev.cache_creation_tokens;
        self.cache_read_tokens += ev.cache_read_tokens;
        self.total_tokens += ev.input_tokens + ev.output_tokens + ev.cache_creation_tokens + ev.cache_read_tokens;
        self.cost_usd += ev.cost_usd;
    }

    fn merge(self: *Totals, other: Totals) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_creation_tokens += other.cache_creation_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.total_tokens += other.total_tokens;
        self.cost_usd += other.cost_usd;
    }
};

const Row = struct {
    key: []const u8,
    totals: Totals,
    models: std.StringHashMap(void),
    projects: std.StringHashMap(void),

    fn init(allocator: Allocator, key: []const u8) Row {
        return .{
            .key = key,
            .totals = .{},
            .models = std.StringHashMap(void).init(allocator),
            .projects = std.StringHashMap(void).init(allocator),
        };
    }
};

const SessionRow = struct {
    session_id: []const u8,
    project: []const u8,
    last_activity: i64,
    totals: Totals,
    models: std.StringHashMap(void),

    fn init(allocator: Allocator, session_id: []const u8, project: []const u8) SessionRow {
        return .{
            .session_id = session_id,
            .project = project,
            .last_activity = 0,
            .totals = .{},
            .models = std.StringHashMap(void).init(allocator),
        };
    }
};

// ============================================================================
// CLI Argument Parsing
// ============================================================================

const Command = enum { daily, weekly, monthly, sessions, blocks, statusline, help };

const Args = struct {
    command: Command = .daily,
    data_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    json_output: bool = false,
    compact: bool = false,
    breakdown: bool = false,
    order_asc: bool = false,
    timezone_offset: i32 = 0,
    owns_data_dirs: bool = false,

    fn deinit(self: *Args, allocator: Allocator) void {
        if (self.owns_data_dirs) {
            for (self.data_dirs.items) |dir| allocator.free(dir);
        }
        self.data_dirs.deinit(allocator);
    }
};

fn parseArgs(allocator: Allocator, init: std.process.Init) !Args {
    var args = Args{};
    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next();

    while (arg_iter.next()) |arg| {
        if (mem.eql(u8, arg, "daily")) args.command = .daily
        else if (mem.eql(u8, arg, "weekly")) args.command = .weekly
        else if (mem.eql(u8, arg, "monthly")) args.command = .monthly
        else if (mem.eql(u8, arg, "sessions")) args.command = .sessions
        else if (mem.eql(u8, arg, "blocks")) args.command = .blocks
        else if (mem.eql(u8, arg, "statusline")) args.command = .statusline
        else if (mem.eql(u8, arg, "help") or mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) args.command = .help
        else if (mem.eql(u8, arg, "--json")) args.json_output = true
        else if (mem.eql(u8, arg, "--compact")) args.compact = true
        else if (mem.eql(u8, arg, "--breakdown")) args.breakdown = true
        else if (mem.eql(u8, arg, "--order")) {
            if (arg_iter.next()) |order| args.order_asc = mem.eql(u8, order, "asc");
        } else if (mem.eql(u8, arg, "--data-dir")) {
            if (arg_iter.next()) |dir| try args.data_dirs.append(allocator, dir);
        } else if (mem.eql(u8, arg, "--timezone")) {
            if (arg_iter.next()) |tz| args.timezone_offset = parseTimezoneOffset(tz);
        }
    }

    if (args.data_dirs.items.len == 0) {
        if (init.environ_map.get("HOME")) |home| {
            try args.data_dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.config/claude", .{home}));
            try args.data_dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.claude", .{home}));
            args.owns_data_dirs = true;
        }
    }
    return args;
}

fn parseTimezoneOffset(tz: []const u8) i32 {
    if (tz.len < 5) return 0;
    const sign: i32 = if (tz[0] == '-') -1 else 1;
    const start: usize = if (tz[0] == '+' or tz[0] == '-') 1 else 0;
    const hours = std.fmt.parseInt(i32, tz[start .. start + 2], 10) catch 0;
    const mins = std.fmt.parseInt(i32, tz[start + 3 .. start + 5], 10) catch 0;
    return sign * (hours * 60 + mins);
}

// ============================================================================
// JSONL Parsing
// ============================================================================

// comptime dupe_strings: true frees content after parsing (strings duped to allocator)
//                        false keeps content in arena (strings reference content directly)
fn parseJsonlFile(comptime dupe_strings: bool, allocator: Allocator, path: []const u8, events: *std.ArrayListUnmanaged(UsageEvent), project: []const u8) void {
    const file = fs.cwd().openFile(app_io, path, .{}) catch return;
    defer file.close(app_io);

    // Read through EOF: 0.17's allocating file reader stops at a cached size,
    // while the pinned 0.15.2 reader includes bytes appended during the read.
    const cap = 512 * 1024 * 1024;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var chunk: [65536]u8 = undefined;
    while (bytes.items.len < cap) {
        const room = @min(chunk.len, cap - bytes.items.len);
        const n = file.readStreaming(app_io, &.{chunk[0..room]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return,
        };
        bytes.appendSlice(allocator, chunk[0..n]) catch return;
    }
    if (bytes.items.len == cap) {
        while (true) {
            const n = file.readStreaming(app_io, &.{chunk[0..1]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return,
            };
            if (n != 0) return;
        }
    }
    const content = bytes.toOwnedSlice(allocator) catch return;
    defer if (dupe_strings) allocator.free(content);

    var pos: usize = 0;
    while (pos < content.len) {
        const newline_pos = mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const line = content[pos..newline_pos];
        pos = newline_pos + 1;
        parseLine(dupe_strings, allocator, line, events, project) catch @panic("OOM in parseLine");
    }
}

// Single-pass JSON parser using SIMD-friendly quote search
// comptime dupe_strings: true when content buffer will be freed after parsing
fn parseLine(comptime dupe_strings: bool, allocator: Allocator, line: []const u8, events: *std.ArrayListUnmanaged(UsageEvent), project: []const u8) !void {
    if (line.len < 50) return;

    var timestamp: []const u8 = "";
    var session_id: []const u8 = "";
    var model: []const u8 = "";
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var cache_creation: u64 = 0;
    var cache_read: u64 = 0;
    var cost_usd: ?f64 = null;
    var has_input = false;

    const b = line;
    var pos: usize = 0;

    while (pos < line.len) {
        const q1 = mem.indexOfScalarPos(u8, b, pos, '"') orelse break;
        const key_start = q1 + 1;
        const q2 = mem.indexOfScalarPos(u8, b, key_start, '"') orelse break;
        const key = b[key_start..q2];
        pos = q2 + 1;

        // Verify colon follows (this is a key, not a string value)
        var colon_pos = pos;
        while (colon_pos < b.len and (b[colon_pos] == ' ' or b[colon_pos] == '\t')) : (colon_pos += 1) {}
        if (colon_pos >= b.len or b[colon_pos] != ':') continue;
        pos = colon_pos + 1;
        while (pos < b.len and (b[pos] == ' ' or b[pos] == '\t')) : (pos += 1) {}
        if (pos >= b.len) break;

        // Dispatch on first char + length
        const key_len = key.len;
        switch (key[0]) {
            't' => if (key_len == 9 and mem.eql(u8, key, "timestamp")) {
                if (b[pos] == '"') {
                    pos += 1;
                    const end = mem.indexOfScalarPos(u8, b, pos, '"') orelse break;
                    timestamp = b[pos..end];
                    pos = end + 1;
                }
            },
            's' => if (key_len == 9 and mem.eql(u8, key, "sessionId")) {
                if (b[pos] == '"') {
                    pos += 1;
                    const end = mem.indexOfScalarPos(u8, b, pos, '"') orelse break;
                    session_id = b[pos..end];
                    pos = end + 1;
                }
            },
            'm' => if (key_len == 5 and mem.eql(u8, key, "model")) {
                if (b[pos] == '"') {
                    pos += 1;
                    const end = mem.indexOfScalarPos(u8, b, pos, '"') orelse break;
                    model = b[pos..end];
                    pos = end + 1;
                }
            },
            'i' => if (key_len == 12 and mem.eql(u8, key, "input_tokens")) {
                input_tokens = parseU64At(b, pos);
                has_input = true;
            },
            'o' => if (key_len == 13 and mem.eql(u8, key, "output_tokens")) {
                output_tokens = parseU64At(b, pos);
            },
            'c' => {
                if (key_len == 27 and mem.eql(u8, key, "cache_creation_input_tokens")) {
                    cache_creation = parseU64At(b, pos);
                } else if (key_len == 23 and mem.eql(u8, key, "cache_read_input_tokens")) {
                    cache_read = parseU64At(b, pos);
                } else if (key_len == 7 and mem.eql(u8, key, "costUSD")) {
                    const start = pos;
                    while (pos < b.len and ((b[pos] >= '0' and b[pos] <= '9') or b[pos] == '.' or b[pos] == '-' or b[pos] == 'e' or b[pos] == 'E')) : (pos += 1) {}
                    cost_usd = std.fmt.parseFloat(f64, b[start..pos]) catch null;
                }
            },
            else => {},
        }
    }

    if (!has_input) return;

    // Skip records with invalid timestamps (Rust filters these out)
    const ts = parseIsoTimestamp(timestamp);
    if (ts == 0) return;

    const cost = cost_usd orelse calculateCost(model, input_tokens, output_tokens, cache_creation, cache_read);

    try events.append(allocator, .{
        .timestamp = ts,
        .model = if (dupe_strings) try allocator.dupe(u8, model) else model,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_creation_tokens = cache_creation,
        .cache_read_tokens = cache_read,
        .cost_usd = cost,
        .session_id = if (dupe_strings) try allocator.dupe(u8, session_id) else session_id,
        .project = project,
    });
}

// Fast u64 parsing at position
fn parseU64At(b: []const u8, start: usize) u64 {
    var val: u64 = 0;
    var i = start;
    while (i < b.len and b[i] >= '0' and b[i] <= '9') : (i += 1) {
        val = val * 10 + (b[i] - '0');
    }
    return val;
}


fn parseIsoTimestamp(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return 0;
    return epochFromDate(year, month, day, hour, minute, second);
}

fn epochFromDate(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    var days: i64 = 0;
    var y: i32 = 1970;
    while (y < year) : (y += 1) days += if (isLeapYear(y)) 366 else 365;
    const dim = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += dim[m - 1];
        if (m == 2 and isLeapYear(year)) days += 1;
    }
    return (days + day - 1) * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

// ============================================================================
// Parallel File Processing
// ============================================================================

const FileTask = struct {
    path: []const u8,
    project: []const u8,
    size: u64,
};

const ParallelThreadData = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayListUnmanaged(UsageEvent),
};

// Result of collectEvents - caller must call deinit() when done with events
const CollectResult = struct {
    events: std.ArrayListUnmanaged(UsageEvent),
    // Thread arenas that hold string data for events - freed in deinit
    thread_data: ?[]ParallelThreadData,
    allocator: Allocator,

    pub fn deinit(self: *CollectResult) void {
        if (self.thread_data) |td| {
            for (td) |*t| t.arena.deinit();
            self.allocator.free(td);
        }
        self.events.deinit(self.allocator);
    }
};

fn collectEvents(allocator: Allocator, string_arena: Allocator, data_dirs: []const []const u8) !CollectResult {
    var files: std.ArrayListUnmanaged(FileTask) = .empty;
    defer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }

    for (data_dirs) |base_dir| {
        const projects_path = try std.fmt.allocPrint(allocator, "{s}/projects", .{base_dir});
        defer allocator.free(projects_path);

        var dir = fs.openDirAbsolute(app_io, projects_path, .{ .iterate = true }) catch continue;
        defer dir.close(app_io);
        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();

        while (walker.next(app_io) catch null) |entry| {
            if (entry.kind != .file or !mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ projects_path, entry.path });
            const project = try string_arena.dupe(u8, extractProjectName(entry.path));
            try files.append(allocator, .{ .path = full_path, .project = project, .size = 0 });
        }
    }

    // Use CPU count for threads
    const num_threads = @min(files.items.len, std.Thread.getCpuCount() catch 4);
    if (num_threads <= 1 or files.items.len < 10) {
        var events: std.ArrayListUnmanaged(UsageEvent) = .empty;
        for (files.items) |f| parseJsonlFile(true, string_arena, f.path, &events, f.project);
        return .{ .events = events, .thread_data = null, .allocator = string_arena };
    }

    var work_index = std.atomic.Value(usize).init(0);
    const thread_data = try allocator.alloc(ParallelThreadData, num_threads);
    for (thread_data) |*td| {
        // page_allocator has less contention than c_allocator for multi-threaded use
        td.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        td.events = .empty;
        td.events.ensureTotalCapacity(td.arena.allocator(), 100_000) catch {};
    }

    var threads = try allocator.alloc(?std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, processFilesWorkStealing, .{ files.items, &work_index, &thread_data[i] }) catch null;
    }

    var total_events: usize = 0;
    for (0..num_threads) |i| {
        if (threads[i]) |t| t.join();
        total_events += thread_data[i].events.items.len;
    }

    var events: std.ArrayListUnmanaged(UsageEvent) = .empty;
    try events.ensureTotalCapacity(allocator, total_events);
    for (thread_data) |td| events.appendSliceAssumeCapacity(td.events.items);

    return .{ .events = events, .thread_data = thread_data, .allocator = allocator };
}

fn processFilesWorkStealing(files: []const FileTask, work_index: *std.atomic.Value(usize), data: *ParallelThreadData) void {
    const alloc = data.arena.allocator();
    while (true) {
        const idx = work_index.fetchAdd(1, .monotonic);
        if (idx >= files.len) break;
        const f = files[idx];
        parseJsonlFile(false, alloc, f.path, &data.events, f.project);
    }
}

fn extractProjectName(path: []const u8) []const u8 {
    return if (mem.indexOf(u8, path, "/")) |idx| path[0..idx] else path;
}

// ============================================================================
// Comptime Generic Aggregation
// ============================================================================

const KeyFormat = enum { date, month };

fn aggregate(comptime key_fmt: KeyFormat, allocator: Allocator, events: []const UsageEvent, tz_offset: i32) !std.ArrayList(Row) {
    var map = std.StringHashMap(*Row).init(allocator);
    defer map.deinit();

    for (events) |ev| {
        const adjusted_ts = ev.timestamp + @as(i64, tz_offset) * 60;
        const key = switch (key_fmt) {
            .date => try formatDate(allocator, adjusted_ts),
            .month => try formatMonth(allocator, adjusted_ts),
        };

        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            const row = try allocator.create(Row);
            row.* = Row.init(allocator, key);
            gop.value_ptr.* = row;
        }
        const row = gop.value_ptr.*;
        row.totals.add(ev);
        try row.models.put(ev.model, {});
        try row.projects.put(ev.project, {});
    }

    var rows: std.ArrayList(Row) = .empty;
    var iter = map.valueIterator();
    while (iter.next()) |row_ptr| try rows.append(allocator, row_ptr.*.*);

    mem.sort(Row, rows.items, {}, struct {
        fn cmp(_: void, a: Row, b: Row) bool {
            return mem.order(u8, b.key, a.key) == .lt;
        }
    }.cmp);
    return rows;
}

fn aggregateSessions(allocator: Allocator, events: []const UsageEvent) !std.ArrayList(SessionRow) {
    var map = std.StringHashMap(*SessionRow).init(allocator);
    defer map.deinit();

    for (events) |ev| {
        const gop = try map.getOrPut(ev.session_id);
        if (!gop.found_existing) {
            const row = try allocator.create(SessionRow);
            row.* = SessionRow.init(allocator, ev.session_id, ev.project);
            gop.value_ptr.* = row;
        }
        const row = gop.value_ptr.*;
        row.totals.add(ev);
        row.last_activity = @max(row.last_activity, ev.timestamp);
        try row.models.put(ev.model, {});
    }

    var rows: std.ArrayList(SessionRow) = .empty;
    var iter = map.valueIterator();
    while (iter.next()) |row_ptr| try rows.append(allocator, row_ptr.*.*);

    mem.sort(SessionRow, rows.items, {}, struct {
        fn cmp(_: void, a: SessionRow, b: SessionRow) bool {
            return b.last_activity < a.last_activity;
        }
    }.cmp);
    return rows;
}

fn aggregateStatusline(allocator: Allocator, events: []const UsageEvent, tz_offset: i32) !struct { date: ?[]const u8, totals: Totals } {
    if (events.len == 0) return .{ .date = null, .totals = .{} };

    var max_ts: i64 = 0;
    for (events) |ev| max_ts = @max(max_ts, ev.timestamp);

    const target_date = try formatDate(allocator, max_ts + @as(i64, tz_offset) * 60);
    var totals = Totals{};

    for (events) |ev| {
        const ev_date = try formatDate(allocator, ev.timestamp + @as(i64, tz_offset) * 60);
        defer allocator.free(ev_date);
        if (mem.eql(u8, ev_date, target_date)) totals.add(ev);
    }
    return .{ .date = target_date, .totals = totals };
}

// ============================================================================
// Date Formatting
// ============================================================================

fn timestampToYMD(timestamp: i64) struct { year: i32, month: u8, day: u8 } {
    const days_since_epoch = @divFloor(timestamp, 86400);
    var year: i32 = 1970;
    var remaining = days_since_epoch;

    while (true) {
        const diy: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining < diy) break;
        remaining -= diy;
        year += 1;
    }

    const dim = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        var d: i64 = dim[month - 1];
        if (month == 2 and isLeapYear(year)) d += 1;
        if (remaining < d) break;
        remaining -= d;
    }
    return .{ .year = year, .month = month, .day = @intCast(remaining + 1) };
}

fn formatDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    const ymd = timestampToYMD(timestamp);
    return std.fmt.allocPrint(allocator, "{}-{:0>2}-{:0>2}", .{ ymd.year, ymd.month, ymd.day });
}

fn formatMonth(allocator: Allocator, timestamp: i64) ![]const u8 {
    const ymd = timestampToYMD(timestamp);
    return std.fmt.allocPrint(allocator, "{}-{:0>2}", .{ ymd.year, ymd.month });
}

// ============================================================================
// Output - ANSI & Table
// ============================================================================

const ANSI = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
};

fn formatProjects(allocator: Allocator, projects: std.StringHashMap(void)) ![]const u8 {
    const count = projects.count();
    if (count == 0) return "-";

    var iter = projects.keyIterator();
    const first = iter.next() orelse return "-";
    const short = shortenProjectName(first.*);
    if (count == 1) return short;

    // Show "first, +N more" format like Rust
    return std.fmt.allocPrint(allocator, "{s}, +{d} more", .{ short, count - 1 });
}

// Shorten project path by removing common prefixes
fn shortenProjectName(name: []const u8) []const u8 {
    var n = name;
    // Handle "-Users-joel-Work-project" -> "project"
    if (mem.startsWith(u8, n, "-Users-")) {
        n = n[7..];
        // Skip username
        if (mem.indexOf(u8, n, "-")) |idx| {
            const rest = n[idx + 1 ..];
            // Skip "Work" or similar
            if (mem.indexOf(u8, rest, "-")) |idx2| {
                return rest[idx2 + 1 ..];
            }
            return rest;
        }
    }
    // Handle "-private-tmp-project" or "-private-var-..." -> last component
    if (mem.startsWith(u8, n, "-private-")) {
        // Find the last meaningful component (after last dash)
        if (mem.lastIndexOf(u8, n, "-")) |idx| {
            if (idx + 1 < n.len) return n[idx + 1 ..];
        }
    }
    return n;
}

fn formatModels(allocator: Allocator, models: std.StringHashMap(void)) ![]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    var iter = models.keyIterator();
    while (iter.next()) |key| {
        if (!mem.eql(u8, key.*, "<synthetic>") and key.*.len > 0) {
            try list.append(allocator, shortenModelName(key.*));
        }
    }
    if (list.items.len == 0) return "-";
    return std.mem.join(allocator, ", ", list.items);
}

fn shortenModelName(model: []const u8) []const u8 {
    if (!mem.startsWith(u8, model, "claude-")) return model;
    const rest = model[7..];
    if (rest.len > 9) {
        const tail = rest[rest.len - 8 ..];
        var all_digits = true;
        for (tail) |c| if (c < '0' or c > '9') {
            all_digits = false;
            break;
        };
        if (all_digits and rest[rest.len - 9] == '-') return rest[0 .. rest.len - 9];
    }
    return rest;
}

fn stripAnsiLen(s: []const u8) usize {
    var len: usize = 0;
    var in_esc = false;
    for (s) |c| {
        if (c == 0x1b) in_esc = true else if (in_esc) {
            if (c == 'm') in_esc = false;
        } else len += 1;
    }
    return len;
}

// ============================================================================
// Comptime Table Builder
// ============================================================================

fn Table(comptime num_cols: usize) type {
    return struct {
        const Self = @This();

        headers: [num_cols][]const u8,
        rows: std.ArrayList([num_cols][]const u8),
        footer: ?[num_cols][]const u8 = null,
        allocator: Allocator,

        pub fn init(allocator: Allocator, headers: [num_cols][]const u8) Self {
            return .{ .headers = headers, .rows = .empty, .allocator = allocator };
        }

        pub fn addRow(self: *Self, cells: [num_cols][]const u8) !void {
            try self.rows.append(self.allocator, cells);
        }

        pub fn setFooter(self: *Self, cells: [num_cols][]const u8) void {
            self.footer = cells;
        }

        pub fn print(self: *Self, title: []const u8) !void {
            const stdout = std.Io.File.stdout();
            var buf: [8192]u8 = undefined;
            var writer = stdout.writerStreaming(app_io, &buf);
            const w = &writer.interface;

            // Title
            try w.print("{s}{s}{s}\n", .{ ANSI.bold, title, ANSI.reset });

            // Calculate widths
            var widths: [num_cols]usize = undefined;
            inline for (0..num_cols) |i| widths[i] = stripAnsiLen(self.headers[i]);
            for (self.rows.items) |row| {
                inline for (0..num_cols) |i| widths[i] = @max(widths[i], stripAnsiLen(row[i]));
            }
            if (self.footer) |f| {
                inline for (0..num_cols) |i| widths[i] = @max(widths[i], stripAnsiLen(f[i]));
            }

            // Top border
            try w.writeAll("┌");
            inline for (0..num_cols) |i| {
                for (0..widths[i] + 2) |_| try w.writeAll("─");
                try w.writeAll(if (i < num_cols - 1) "┬" else "┐\n");
            }

            // Header
            try w.writeAll("│");
            inline for (0..num_cols) |i| {
                try w.print(" {s}{s}{s}{s}", .{ ANSI.cyan, ANSI.bold, self.headers[i], ANSI.reset });
                for (0..widths[i] - stripAnsiLen(self.headers[i]) + 1) |_| try w.writeByte(' ');
                try w.writeAll("│");
            }
            try w.writeAll("\n├");
            inline for (0..num_cols) |i| {
                for (0..widths[i] + 2) |_| try w.writeAll("─");
                try w.writeAll(if (i < num_cols - 1) "┼" else "┤\n");
            }

            // Data rows
            for (self.rows.items) |row| {
                try w.writeAll("│");
                inline for (0..num_cols) |i| {
                    try w.print(" {s}", .{row[i]});
                    for (0..widths[i] - stripAnsiLen(row[i]) + 1) |_| try w.writeByte(' ');
                    try w.writeAll("│");
                }
                try w.writeAll("\n");
            }

            // Footer
            if (self.footer) |f| {
                try w.writeAll("├");
                inline for (0..num_cols) |i| {
                    for (0..widths[i] + 2) |_| try w.writeAll("─");
                    try w.writeAll(if (i < num_cols - 1) "┼" else "┤\n");
                }
                try w.writeAll("│");
                inline for (0..num_cols) |i| {
                    try w.print(" {s}", .{f[i]});
                    for (0..widths[i] - stripAnsiLen(f[i]) + 1) |_| try w.writeByte(' ');
                    try w.writeAll("│");
                }
                try w.writeAll("\n");
            }

            // Bottom border
            try w.writeAll("└");
            inline for (0..num_cols) |i| {
                for (0..widths[i] + 2) |_| try w.writeAll("─");
                try w.writeAll(if (i < num_cols - 1) "┴" else "┘\n");
            }
            try w.flush();
        }
    };
}

// ============================================================================
// Commands - Using comptime table & formatter
// ============================================================================

fn runPeriodReport(comptime key_fmt: KeyFormat, allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const rows = try aggregate(key_fmt, allocator, events, args.timezone_offset);
    const title = if (key_fmt == .date) "Daily usage" else "Monthly usage";

    if (args.json_output) {
        try outputJson(if (key_fmt == .date) "daily" else "monthly", rows.items);
        return;
    }

    var table = Table(7).init(allocator, .{ "Period", "In", "Out", "Total", "Cost", "Projects", "Models" });
    var totals = Totals{};
    var fmt = Fmt(8){};

    for (rows.items) |row| {
        totals.merge(row.totals);
        try table.addRow(.{
            row.key,
            try allocator.dupe(u8, fmt.tokens(row.totals.input_tokens)),
            try allocator.dupe(u8, fmt.tokens(row.totals.output_tokens)),
            try allocator.dupe(u8, fmt.tokens(row.totals.total_tokens)),
            try allocator.dupe(u8, fmt.cost(row.totals.cost_usd)),
            try formatProjects(allocator, row.projects),
            try formatModels(allocator, row.models),
        });
    }

    table.setFooter(.{
        try allocator.dupe(u8, fmt.yellowBold("Total")),
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.input_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.output_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.total_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.cost(totals.cost_usd))),
        "",
        "",
    });
    try table.print(title);
}

fn runSessions(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const rows = try aggregateSessions(allocator, events);

    if (args.json_output) {
        try outputSessionsJson(rows.items);
        return;
    }

    var table = Table(7).init(allocator, .{ "Session", "Project", "In", "Out", "Total", "Cost", "Models" });
    var totals = Totals{};
    var fmt = Fmt(8){};

    for (rows.items) |row| {
        totals.merge(row.totals);
        try table.addRow(.{
            truncateStr(row.session_id, 12),
            truncateStr(row.project, 16),
            try allocator.dupe(u8, fmt.tokens(row.totals.input_tokens)),
            try allocator.dupe(u8, fmt.tokens(row.totals.output_tokens)),
            try allocator.dupe(u8, fmt.tokens(row.totals.total_tokens)),
            try allocator.dupe(u8, fmt.cost(row.totals.cost_usd)),
            try formatModels(allocator, row.models),
        });
    }

    table.setFooter(.{
        try allocator.dupe(u8, fmt.yellowBold("TOTAL")),
        "",
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.input_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.output_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.tokens(totals.total_tokens))),
        try allocator.dupe(u8, fmt.yellow(fmt.cost(totals.cost_usd))),
        "",
    });
    try table.print("Session usage");
}

fn runStatusline(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const result = try aggregateStatusline(allocator, events, args.timezone_offset);

    if (args.json_output) {
        try outputStatuslineJson(result.date, result.totals);
        return;
    }

    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(app_io, &buf);
    const w = &writer.interface;

    if (result.date) |date| {
        var fmt = Fmt(20){};
        try w.print("{s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s} {s}\n", .{
            fmt.cyanBold(date),
            fmt.dim("|"),
            fmt.dim("in"),
            fmt.tokens(result.totals.input_tokens),
            fmt.dim("|"),
            fmt.dim("out"),
            fmt.tokens(result.totals.output_tokens),
            fmt.dim("|"),
            fmt.dim("c/w"),
            fmt.tokens(result.totals.cache_creation_tokens),
            fmt.dim("|"),
            fmt.dim("c/r"),
            fmt.tokens(result.totals.cache_read_tokens),
            fmt.dim("|"),
            fmt.dim("total"),
            fmt.tokens(result.totals.total_tokens),
            fmt.dim("|"),
            fmt.yellowBold(fmt.cost(result.totals.cost_usd)),
        });
    } else {
        try w.writeAll("No data\n");
    }
    try w.flush();
}

fn truncateStr(s: []const u8, max_len: usize) []const u8 {
    return if (s.len <= max_len) s else s[0..max_len];
}

// ============================================================================
// JSON Output
// ============================================================================

fn outputJson(kind: []const u8, rows: []const Row) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(app_io, &buf);
    const w = &writer.interface;

    try w.print("{{\"kind\":\"{s}\",\"rows\":[", .{kind});
    var totals = Totals{};
    for (rows, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"key\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d},\"cost_usd\":{d:.2}}}", .{
            row.key,
            row.totals.input_tokens,
            row.totals.output_tokens,
            row.totals.total_tokens,
            row.totals.cost_usd,
        });
        totals.merge(row.totals);
    }
    try w.print("],\"totals\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d},\"cost_usd\":{d:.2}}}}}\n", .{
        totals.input_tokens,
        totals.output_tokens,
        totals.total_tokens,
        totals.cost_usd,
    });
    try w.flush();
}

fn outputSessionsJson(rows: []const SessionRow) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(app_io, &buf);
    const w = &writer.interface;

    try w.writeAll("{\"kind\":\"sessions\",\"rows\":[");
    var totals = Totals{};
    for (rows, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"session_id\":\"{s}\",\"project\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d},\"cost_usd\":{d:.2}}}", .{
            row.session_id,
            row.project,
            row.totals.input_tokens,
            row.totals.output_tokens,
            row.totals.total_tokens,
            row.totals.cost_usd,
        });
        totals.merge(row.totals);
    }
    try w.print("],\"totals\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d},\"cost_usd\":{d:.2}}}}}\n", .{
        totals.input_tokens,
        totals.output_tokens,
        totals.total_tokens,
        totals.cost_usd,
    });
    try w.flush();
}

fn outputStatuslineJson(date: ?[]const u8, totals: Totals) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(app_io, &buf);
    const w = &writer.interface;

    if (date) |d| {
        try w.print("{{\"kind\":\"statusline\",\"last_date\":\"{s}\",\"totals\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d},\"total_tokens\":{d},\"cost_usd\":{d:.2}}}}}\n", .{
            d,
            totals.input_tokens,
            totals.output_tokens,
            totals.cache_creation_tokens,
            totals.cache_read_tokens,
            totals.total_tokens,
            totals.cost_usd,
        });
    } else {
        try w.writeAll("{\"kind\":\"statusline\",\"last_date\":null,\"totals\":{}}\n");
    }
    try w.flush();
}

// ============================================================================
// Main
// ============================================================================

fn printHelp() !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writerStreaming(app_io, &buf);
    writer.interface.writeAll(
        \\zzusage - Claude Code usage analyzer (Zig)
        \\
        \\Usage: zzusage [command] [options]
        \\
        \\Commands:
        \\  daily       Daily usage (default)
        \\  weekly      Weekly usage
        \\  monthly     Monthly usage
        \\  sessions    Per-session usage
        \\  blocks      5-hour block usage
        \\  statusline  One-line summary
        \\
        \\Options:
        \\  --data-dir <path>   Data directory (repeatable)
        \\  --json              JSON output
        \\  --compact           Compact display
        \\  --breakdown         Show model breakdowns
        \\  --order asc|desc    Sort order
        \\  --timezone +HH:MM   Timezone offset
        \\  --help              Show this help
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) !void {
    app_io = init.io;
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arena for event string data - all event strings live here until program end
    var event_arena = std.heap.ArenaAllocator.init(allocator);
    defer event_arena.deinit();

    var args = try parseArgs(allocator, init);
    defer args.deinit(allocator);

    if (args.command == .help) {
        try printHelp();
        return;
    }

    var result = try collectEvents(allocator, event_arena.allocator(), args.data_dirs.items);
    defer result.deinit();

    // Report keys, rows, and maps live for one command; release them together.
    var report_arena = std.heap.ArenaAllocator.init(allocator);
    defer report_arena.deinit();
    const report_allocator = report_arena.allocator();

    switch (args.command) {
        .daily, .weekly => try runPeriodReport(.date, report_allocator, args, result.events.items),
        .monthly => try runPeriodReport(.month, report_allocator, args, result.events.items),
        .sessions => try runSessions(report_allocator, args, result.events.items),
        .statusline => try runStatusline(report_allocator, args, result.events.items),
        .blocks => try runPeriodReport(.date, report_allocator, args, result.events.items),
        .help => try printHelp(),
    }
}
