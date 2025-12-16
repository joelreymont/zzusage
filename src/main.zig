const std = @import("std");
const fs = std.fs;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const File = fs.File;

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
    owns_data_dirs: bool = false, // true if we allocated the default dirs

    fn deinit(self: *Args, allocator: Allocator) void {
        if (self.owns_data_dirs) {
            for (self.data_dirs.items) |dir| {
                allocator.free(dir);
            }
        }
        self.data_dirs.deinit(allocator);
    }
};

fn parseArgs(allocator: Allocator) !Args {
    var args = Args{};
    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    _ = arg_iter.next();

    while (arg_iter.next()) |arg| {
        if (mem.eql(u8, arg, "daily")) {
            args.command = .daily;
        } else if (mem.eql(u8, arg, "weekly")) {
            args.command = .weekly;
        } else if (mem.eql(u8, arg, "monthly")) {
            args.command = .monthly;
        } else if (mem.eql(u8, arg, "sessions")) {
            args.command = .sessions;
        } else if (mem.eql(u8, arg, "blocks")) {
            args.command = .blocks;
        } else if (mem.eql(u8, arg, "statusline")) {
            args.command = .statusline;
        } else if (mem.eql(u8, arg, "help") or mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            args.command = .help;
        } else if (mem.eql(u8, arg, "--json")) {
            args.json_output = true;
        } else if (mem.eql(u8, arg, "--compact")) {
            args.compact = true;
        } else if (mem.eql(u8, arg, "--breakdown")) {
            args.breakdown = true;
        } else if (mem.eql(u8, arg, "--order")) {
            if (arg_iter.next()) |order| {
                args.order_asc = mem.eql(u8, order, "asc");
            }
        } else if (mem.eql(u8, arg, "--data-dir")) {
            if (arg_iter.next()) |dir| {
                try args.data_dirs.append(allocator, dir);
            }
        } else if (mem.eql(u8, arg, "--timezone")) {
            if (arg_iter.next()) |tz| {
                args.timezone_offset = parseTimezoneOffset(tz);
            }
        }
    }

    if (args.data_dirs.items.len == 0) {
        if (std.posix.getenv("HOME")) |home| {
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
// JSONL Parsing - Fast manual extraction (no full JSON parse)
// ============================================================================

fn parseJsonlFile(allocator: Allocator, path: []const u8, events: *std.ArrayListUnmanaged(UsageEvent), project: []const u8) !void {
    const file = fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    // Read entire file (arena allocator handles memory)
    const content = file.readToEndAlloc(allocator, 500 * 1024 * 1024) catch return;
    // Note: don't free - arena allocator handles it

    var pos: usize = 0;
    while (pos < content.len) {
        const line_end = mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const line = content[pos..line_end];
        pos = line_end + 1;

        if (line.len == 0) continue;
        if (findSubstring(line, "input_tokens") == null) continue;

        const input_tokens = extractU64(line, "\"input_tokens\":") orelse continue;
        const output_tokens = extractU64(line, "\"output_tokens\":") orelse 0;
        const cache_creation = extractU64(line, "\"cache_creation_input_tokens\":") orelse 0;
        const cache_read = extractU64(line, "\"cache_read_input_tokens\":") orelse 0;
        const cost_usd = extractF64(line, "\"costUSD\":") orelse 0.0;
        const timestamp = extractString(line, "\"timestamp\":\"") orelse "";
        const model = extractString(line, "\"model\":\"") orelse "";
        const session_id = extractString(line, "\"sessionId\":\"") orelse "";

        events.append(allocator, .{
            .timestamp = parseIsoTimestamp(timestamp),
            .model = allocator.dupe(u8, model) catch "",
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_creation_tokens = cache_creation,
            .cache_read_tokens = cache_read,
            .cost_usd = cost_usd,
            .session_id = allocator.dupe(u8, session_id) catch "",
            .project = allocator.dupe(u8, project) catch "",
        }) catch {};
    }
}

// Use memmem-style search - first byte + verify
fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    const first = needle[0];
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        // Use SIMD-optimized single-byte search
        const idx = mem.indexOfScalarPos(u8, haystack, pos, first) orelse return null;
        if (idx + needle.len > haystack.len) return null;
        if (mem.eql(u8, haystack[idx..][0..needle.len], needle)) return idx;
        pos = idx + 1;
    }
    return null;
}

fn extractU64(line: []const u8, key: []const u8) ?u64 {
    const idx = findSubstring(line, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < line.len and (line[end] >= '0' and line[end] <= '9')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, line[start..end], 10) catch null;
}

fn extractF64(line: []const u8, key: []const u8) ?f64 {
    const idx = findSubstring(line, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < line.len and (line[end] == '.' or line[end] == '-' or (line[end] >= '0' and line[end] <= '9'))) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseFloat(f64, line[start..end]) catch null;
}

fn extractString(line: []const u8, key: []const u8) ?[]const u8 {
    const idx = findSubstring(line, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < line.len and line[end] != '"') : (end += 1) {}
    if (end == start or end >= line.len) return null;
    return line[start..end];
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
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += days_in_month[m - 1];
        if (m == 2 and isLeapYear(year)) days += 1;
    }
    days += day - 1;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

// ============================================================================
// Data Collection - Parallel file processing
// ============================================================================

const FileTask = struct {
    path: []const u8,
    project: []const u8,
};

fn collectEvents(allocator: Allocator, data_dirs: []const []const u8) !std.ArrayListUnmanaged(UsageEvent) {
    // Phase 1: Collect all file paths
    var files = std.ArrayListUnmanaged(FileTask){};
    defer {
        for (files.items) |f| {
            allocator.free(f.path);
            allocator.free(f.project);
        }
        files.deinit(allocator);
    }

    for (data_dirs) |base_dir| {
        const projects_path = try std.fmt.allocPrint(allocator, "{s}/projects", .{base_dir});
        defer allocator.free(projects_path);

        var dir = fs.openDirAbsolute(projects_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var walker = dir.walk(allocator) catch continue;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!mem.endsWith(u8, entry.basename, ".jsonl")) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ projects_path, entry.path });
            const project = try allocator.dupe(u8, extractProjectName(entry.path));
            try files.append(allocator, .{ .path = full_path, .project = project });
        }
    }

    // Phase 2: Process files in parallel using work-stealing pattern
    const num_threads = @min(files.items.len, std.Thread.getCpuCount() catch 4);
    if (num_threads <= 1 or files.items.len < 10) {
        var events = std.ArrayListUnmanaged(UsageEvent){};
        for (files.items) |f| {
            try parseJsonlFile(allocator, f.path, &events, f.project);
        }
        return events;
    }

    // Shared work queue index (atomic counter)
    var work_index = std.atomic.Value(usize).init(0);

    // Per-thread arenas and event storage (arenas must outlive events)
    var thread_data = try allocator.alloc(ParallelThreadData, num_threads);
    // Note: arenas are intentionally not freed - CLI tool exits anyway
    for (thread_data) |*td| {
        td.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        td.events = .{};
    }

    var threads = try allocator.alloc(?std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, processFilesWorkStealing, .{
            files.items,
            &work_index,
            &thread_data[i],
        }) catch null;
    }

    // Join and merge
    var total_events: usize = 0;
    for (0..num_threads) |i| {
        if (threads[i]) |t| t.join();
        total_events += thread_data[i].events.items.len;
    }

    // Merge events (arenas stay alive for program lifetime)
    var events = std.ArrayListUnmanaged(UsageEvent){};
    try events.ensureTotalCapacity(allocator, total_events);
    for (thread_data) |td| {
        events.appendSliceAssumeCapacity(td.events.items);
    }

    return events;
}


const ParallelThreadData = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayListUnmanaged(UsageEvent),
};

fn processFilesWorkStealing(
    files: []const FileTask,
    work_index: *std.atomic.Value(usize),
    data: *ParallelThreadData,
) void {
    const alloc = data.arena.allocator();
    while (true) {
        const idx = work_index.fetchAdd(1, .monotonic);
        if (idx >= files.len) break;
        parseJsonlFile(alloc, files[idx].path, &data.events, files[idx].project) catch {};
    }
}

fn extractProjectName(path: []const u8) []const u8 {
    if (mem.indexOf(u8, path, "/")) |idx| return path[0..idx];
    return path;
}

// ============================================================================
// Aggregation
// ============================================================================

fn aggregateDaily(allocator: Allocator, events: []const UsageEvent, tz_offset: i32) !std.ArrayList(Row) {
    var map = std.StringHashMap(*Row).init(allocator);
    defer map.deinit();

    for (events) |ev| {
        const adjusted_ts = ev.timestamp + @as(i64, tz_offset) * 60;
        const key = try formatDate(allocator, adjusted_ts);

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

    var rows = std.ArrayList(Row){};
    var iter = map.valueIterator();
    while (iter.next()) |row_ptr| {
        try rows.append(allocator, row_ptr.*.*);
    }

    mem.sort(Row, rows.items, {}, struct {
        fn cmp(_: void, a: Row, b: Row) bool {
            return mem.order(u8, b.key, a.key) == .lt;
        }
    }.cmp);

    return rows;
}

fn aggregateMonthly(allocator: Allocator, events: []const UsageEvent, tz_offset: i32) !std.ArrayList(Row) {
    var map = std.StringHashMap(*Row).init(allocator);
    defer map.deinit();

    for (events) |ev| {
        const adjusted_ts = ev.timestamp + @as(i64, tz_offset) * 60;
        const key = try formatMonth(allocator, adjusted_ts);

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

    var rows = std.ArrayList(Row){};
    var iter = map.valueIterator();
    while (iter.next()) |row_ptr| {
        try rows.append(allocator, row_ptr.*.*);
    }

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

    var rows = std.ArrayList(SessionRow){};
    var iter = map.valueIterator();
    while (iter.next()) |row_ptr| {
        try rows.append(allocator, row_ptr.*.*);
    }

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

    const adjusted_max = max_ts + @as(i64, tz_offset) * 60;
    const target_date = try formatDate(allocator, adjusted_max);

    var totals = Totals{};
    for (events) |ev| {
        const adjusted_ts = ev.timestamp + @as(i64, tz_offset) * 60;
        const ev_date = try formatDate(allocator, adjusted_ts);
        defer allocator.free(ev_date);

        if (mem.eql(u8, ev_date, target_date)) totals.add(ev);
    }

    return .{ .date = target_date, .totals = totals };
}

// ============================================================================
// Date Formatting
// ============================================================================

fn formatDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    const days_since_epoch = @divFloor(timestamp, 86400);
    var year: i32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        var dim: i64 = days_in_month[month - 1];
        if (month == 2 and isLeapYear(year)) dim += 1;
        if (remaining_days < dim) break;
        remaining_days -= dim;
    }

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, @as(u8, @intCast(remaining_days + 1)) });
}

fn formatMonth(allocator: Allocator, timestamp: i64) ![]const u8 {
    const days_since_epoch = @divFloor(timestamp, 86400);
    var year: i32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    while (month <= 12) : (month += 1) {
        var dim: i64 = days_in_month[month - 1];
        if (month == 2 and isLeapYear(year)) dim += 1;
        if (remaining_days < dim) break;
        remaining_days -= dim;
    }

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}", .{ year, month });
}

// ============================================================================
// Output Formatting
// ============================================================================

const ANSI = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
};

fn formatTokensCompact(buf: []u8, value: u64) []const u8 {
    if (value >= 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}B", .{@as(f64, @floatFromInt(value)) / 1_000_000_000.0}) catch "?";
    } else if (value >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1_000_000.0}) catch "?";
    } else if (value >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.1}K", .{@as(f64, @floatFromInt(value)) / 1_000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

fn formatCostCompact(buf: []u8, value: f64) []const u8 {
    if (value >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "${d:.1}M", .{value / 1_000_000.0}) catch "?";
    } else if (value >= 1_000.0) {
        return std.fmt.bufPrint(buf, "${d:.0}K", .{value / 1_000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "${d:.0}", .{value}) catch "?";
}

fn formatModels(allocator: Allocator, models: std.StringHashMap(void)) ![]const u8 {
    var list = std.ArrayList([]const u8){};
    defer list.deinit(allocator);

    var iter = models.keyIterator();
    while (iter.next()) |key| {
        if (!mem.eql(u8, key.*, "<synthetic>")) {
            try list.append(allocator, shortenModelName(key.*));
        }
    }

    if (list.items.len == 0) return "-";
    return std.mem.join(allocator, ", ", list.items);
}

fn shortenModelName(model: []const u8) []const u8 {
    if (mem.startsWith(u8, model, "claude-")) {
        const rest = model[7..];
        if (rest.len > 9) {
            const potential_date = rest[rest.len - 8 ..];
            var all_digits = true;
            for (potential_date) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (all_digits and rest[rest.len - 9] == '-') {
                return rest[0 .. rest.len - 9];
            }
        }
        return rest;
    }
    return model;
}

// ============================================================================
// Output Helpers
// ============================================================================

fn getStdoutWriter() struct { writer: fs.File.Writer, io: *std.Io.Writer } {
    const stdout_file = fs.File.stdout();
    const writer_storage = struct {
        var buf: [8192]u8 = undefined;
        var writer: fs.File.Writer = undefined;
    };
    writer_storage.writer = stdout_file.writer(&writer_storage.buf);
    return .{ .writer = writer_storage.writer, .io = &writer_storage.writer.interface };
}

fn writeByteNTimes(w: *std.Io.Writer, byte: u8, n: usize) !void {
    for (0..n) |_| try w.writeByte(byte);
}

fn writeHorizLine(w: *std.Io.Writer, n: usize) !void {
    for (0..n) |_| try w.writeAll("─");
}

// ============================================================================
// Table Output
// ============================================================================

fn printTable(allocator: Allocator, headers: []const []const u8, rows: []const []const []const u8, footer: ?[]const []const u8) !void {
    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    var widths = try allocator.alloc(usize, headers.len);
    defer allocator.free(widths);

    for (headers, 0..) |h, i| widths[i] = stripAnsiLen(h);

    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i < widths.len) widths[i] = @max(widths[i], stripAnsiLen(cell));
        }
    }

    if (footer) |f| {
        for (f, 0..) |cell, i| {
            if (i < widths.len) widths[i] = @max(widths[i], stripAnsiLen(cell));
        }
    }

    // Top border
    try w.writeAll("┌");
    for (widths, 0..) |width, i| {
        try writeHorizLine(w, width + 2);
        if (i < widths.len - 1) try w.writeAll("┬") else try w.writeAll("┐\n");
    }

    // Header
    try w.writeAll("│");
    for (headers, 0..) |h, i| {
        try w.print(" {s}{s}{s}{s}", .{ ANSI.cyan, ANSI.bold, h, ANSI.reset });
        try writeByteNTimes(w, ' ', widths[i] - stripAnsiLen(h) + 1);
        try w.writeAll("│");
    }
    try w.writeAll("\n");

    // Header separator
    try w.writeAll("├");
    for (widths, 0..) |width, i| {
        try writeHorizLine(w, width + 2);
        if (i < widths.len - 1) try w.writeAll("┼") else try w.writeAll("┤\n");
    }

    // Data rows
    for (rows) |row| {
        try w.writeAll("│");
        for (row, 0..) |cell, i| {
            if (i < widths.len) {
                try w.print(" {s}", .{cell});
                try writeByteNTimes(w, ' ', widths[i] - stripAnsiLen(cell) + 1);
                try w.writeAll("│");
            }
        }
        try w.writeAll("\n");
    }

    // Footer
    if (footer) |f| {
        try w.writeAll("├");
        for (widths, 0..) |width, i| {
            try writeHorizLine(w, width + 2);
            if (i < widths.len - 1) try w.writeAll("┼") else try w.writeAll("┤\n");
        }

        try w.writeAll("│");
        for (f, 0..) |cell, i| {
            if (i < widths.len) {
                try w.print(" {s}", .{cell});
                try writeByteNTimes(w, ' ', widths[i] - stripAnsiLen(cell) + 1);
                try w.writeAll("│");
            }
        }
        try w.writeAll("\n");
    }

    // Bottom border
    try w.writeAll("└");
    for (widths, 0..) |width, i| {
        try writeHorizLine(w, width + 2);
        if (i < widths.len - 1) try w.writeAll("┴") else try w.writeAll("┘\n");
    }

    try w.flush();
}

fn stripAnsiLen(s: []const u8) usize {
    var len: usize = 0;
    var in_escape = false;
    for (s) |c| {
        if (c == 0x1b) {
            in_escape = true;
        } else if (in_escape) {
            if (c == 'm') in_escape = false;
        } else {
            len += 1;
        }
    }
    return len;
}

// ============================================================================
// Commands
// ============================================================================

fn printHelp() void {
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll(
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
}

fn runDaily(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    const rows = try aggregateDaily(allocator, events, args.timezone_offset);

    if (args.json_output) {
        try outputJson("daily", rows.items);
        return;
    }

    try w.print("{s}Daily usage{s}\n", .{ ANSI.bold, ANSI.reset });
    try w.flush();

    const headers = [_][]const u8{ "Period", "In", "Out", "Total", "Cost", "Models" };
    var table_rows = std.ArrayList([]const []const u8){};
    defer table_rows.deinit(allocator);

    var totals = Totals{};
    for (rows.items) |row| {
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.total_tokens += row.totals.total_tokens;
        totals.cost_usd += row.totals.cost_usd;

        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var buf4: [32]u8 = undefined;

        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = row.key;
        cells[1] = try allocator.dupe(u8, formatTokensCompact(&buf1, row.totals.input_tokens));
        cells[2] = try allocator.dupe(u8, formatTokensCompact(&buf2, row.totals.output_tokens));
        cells[3] = try allocator.dupe(u8, formatTokensCompact(&buf3, row.totals.total_tokens));
        cells[4] = try allocator.dupe(u8, formatCostCompact(&buf4, row.totals.cost_usd));
        cells[5] = try formatModels(allocator, row.models);
        try table_rows.append(allocator, cells);
    }

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;
    var buf4: [32]u8 = undefined;

    const footer = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}{s}Total{s}", .{ ANSI.yellow, ANSI.bold, ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf1, totals.input_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf2, totals.output_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf3, totals.total_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatCostCompact(&buf4, totals.cost_usd), ANSI.reset }),
        "",
    };

    try printTable(allocator, &headers, table_rows.items, &footer);
}

fn runMonthly(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    const rows = try aggregateMonthly(allocator, events, args.timezone_offset);

    if (args.json_output) {
        try outputJson("monthly", rows.items);
        return;
    }

    try w.print("{s}Monthly usage{s}\n", .{ ANSI.bold, ANSI.reset });
    try w.flush();

    const headers = [_][]const u8{ "Period", "In", "Out", "Total", "Cost", "Models" };
    var table_rows = std.ArrayList([]const []const u8){};
    defer table_rows.deinit(allocator);

    var totals = Totals{};
    for (rows.items) |row| {
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.total_tokens += row.totals.total_tokens;
        totals.cost_usd += row.totals.cost_usd;

        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var buf4: [32]u8 = undefined;

        const cells = try allocator.alloc([]const u8, 6);
        cells[0] = row.key;
        cells[1] = try allocator.dupe(u8, formatTokensCompact(&buf1, row.totals.input_tokens));
        cells[2] = try allocator.dupe(u8, formatTokensCompact(&buf2, row.totals.output_tokens));
        cells[3] = try allocator.dupe(u8, formatTokensCompact(&buf3, row.totals.total_tokens));
        cells[4] = try allocator.dupe(u8, formatCostCompact(&buf4, row.totals.cost_usd));
        cells[5] = try formatModels(allocator, row.models);
        try table_rows.append(allocator, cells);
    }

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;
    var buf4: [32]u8 = undefined;

    const footer = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}{s}Total{s}", .{ ANSI.yellow, ANSI.bold, ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf1, totals.input_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf2, totals.output_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf3, totals.total_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatCostCompact(&buf4, totals.cost_usd), ANSI.reset }),
        "",
    };

    try printTable(allocator, &headers, table_rows.items, &footer);
}

fn runSessions(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    const rows = try aggregateSessions(allocator, events);

    if (args.json_output) {
        try outputSessionsJson(rows.items);
        return;
    }

    try w.print("{s}Session usage{s}\n", .{ ANSI.bold, ANSI.reset });
    try w.flush();

    const headers = [_][]const u8{ "Session", "Project", "In", "Out", "Total", "Cost", "Models" };
    var table_rows = std.ArrayList([]const []const u8){};
    defer table_rows.deinit(allocator);

    var totals = Totals{};
    for (rows.items) |row| {
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.total_tokens += row.totals.total_tokens;
        totals.cost_usd += row.totals.cost_usd;

        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var buf4: [32]u8 = undefined;

        const cells = try allocator.alloc([]const u8, 7);
        cells[0] = truncateStr(row.session_id, 12);
        cells[1] = truncateStr(row.project, 16);
        cells[2] = try allocator.dupe(u8, formatTokensCompact(&buf1, row.totals.input_tokens));
        cells[3] = try allocator.dupe(u8, formatTokensCompact(&buf2, row.totals.output_tokens));
        cells[4] = try allocator.dupe(u8, formatTokensCompact(&buf3, row.totals.total_tokens));
        cells[5] = try allocator.dupe(u8, formatCostCompact(&buf4, row.totals.cost_usd));
        cells[6] = try formatModels(allocator, row.models);
        try table_rows.append(allocator, cells);
    }

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    var buf3: [32]u8 = undefined;
    var buf4: [32]u8 = undefined;

    const footer = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}{s}TOTAL{s}", .{ ANSI.yellow, ANSI.bold, ANSI.reset }),
        "",
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf1, totals.input_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf2, totals.output_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatTokensCompact(&buf3, totals.total_tokens), ANSI.reset }),
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ANSI.yellow, formatCostCompact(&buf4, totals.cost_usd), ANSI.reset }),
        "",
    };

    try printTable(allocator, &headers, table_rows.items, &footer);
}

fn runStatusline(allocator: Allocator, args: Args, events: []const UsageEvent) !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    const result = try aggregateStatusline(allocator, events, args.timezone_offset);

    if (args.json_output) {
        try outputStatuslineJson(result.date, result.totals);
        return;
    }

    if (result.date) |date| {
        var buf1: [32]u8 = undefined;
        var buf2: [32]u8 = undefined;
        var buf3: [32]u8 = undefined;
        var buf4: [32]u8 = undefined;
        var buf5: [32]u8 = undefined;
        var buf6: [32]u8 = undefined;

        // Split into multiple prints to stay under 32 arg limit
        try w.print("{s}{s}{s} | in {s} | out {s}", .{
            ANSI.cyan,
            date,
            ANSI.reset,
            formatTokensCompact(&buf1, result.totals.input_tokens),
            formatTokensCompact(&buf2, result.totals.output_tokens),
        });
        try w.print(" | c/w {s} | c/r {s} | total {s} | {s}{s}{s}\n", .{
            formatTokensCompact(&buf3, result.totals.cache_creation_tokens),
            formatTokensCompact(&buf4, result.totals.cache_read_tokens),
            formatTokensCompact(&buf5, result.totals.total_tokens),
            ANSI.yellow,
            formatCostCompact(&buf6, result.totals.cost_usd),
            ANSI.reset,
        });
    } else {
        try w.writeAll("No data\n");
    }
    try w.flush();
}

fn truncateStr(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// ============================================================================
// JSON Output
// ============================================================================

fn outputJson(kind: []const u8, rows: []const Row) !void {
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

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
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.total_tokens += row.totals.total_tokens;
        totals.cost_usd += row.totals.cost_usd;
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
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

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
        totals.input_tokens += row.totals.input_tokens;
        totals.output_tokens += row.totals.output_tokens;
        totals.total_tokens += row.totals.total_tokens;
        totals.cost_usd += row.totals.cost_usd;
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
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try parseArgs(allocator);
    defer args.deinit(allocator);

    if (args.command == .help) {
        printHelp();
        return;
    }

    var events = try collectEvents(allocator, args.data_dirs.items);
    defer events.deinit(allocator);

    switch (args.command) {
        .daily => try runDaily(allocator, args, events.items),
        .monthly => try runMonthly(allocator, args, events.items),
        .sessions => try runSessions(allocator, args, events.items),
        .statusline => try runStatusline(allocator, args, events.items),
        .weekly => try runDaily(allocator, args, events.items),
        .blocks => try runDaily(allocator, args, events.items),
        .help => printHelp(),
    }
}
