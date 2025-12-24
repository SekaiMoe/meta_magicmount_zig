const std = @import("std");
const os = std.os;
const linux = os.linux;
const Allocator = std.mem.Allocator;

// --- Constants ---
pub const PATH_MAX = 4096;
pub const TMPFS_MAGIC: u64 = 0x01021994;
pub const SELINUX_XATTR = "security.selinux";
pub const DEFAULT_TEMP_DIR = "/dev/.magic_mount";

// --- Logging ---
pub const LogLevel = packed enum(i32) {
    debug = 0,
    info = 1,
    warn = 2,
    error = 3,
};

var g_log_level: LogLevel = .info;
var g_log_file: ?std.fs.File = null;
var g_log_initialized: bool = false;

const LogEntry = struct { line: []u8 };
var g_log_buf: std.ArrayList(LogEntry) = undefined;
var g_log_buf_allocator: Allocator = undefined;

pub fn logInit(allocator: Allocator) void {
    g_log_buf = std.ArrayList(LogEntry).init(allocator);
    g_log_buf_allocator = allocator;
}

pub fn logSetFile(file: ?std.fs.File) void {
    g_log_file = file;

    if (!g_log_initialized) {
        g_log_initialized = true;
        logFlushBuffer();
    }
}

pub fn logSetLevel(level: LogLevel) void {
    g_log_level = level;
}

fn logLevelStr(lv: LogLevel) []const u8 {
    return switch (lv) {
        .error => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
}

fn logFlushBuffer() void {
    const out = if (g_log_file) |f| f.writer() else std.io.getStdErr().writer();
    for (g_log_buf.items) |entry| {
        _ = out.print("{s}\n", .{entry.line}) catch {};
        g_log_buf_allocator.free(entry.line);
    }
    g_log_buf.clearAndFree();
}

pub fn logWrite(
    comptime level: LogLevel,
    comptime file: []const u8,
    line: usize,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(g_log_level)) return;

    var buf: [1024]u8 = undefined;
    const writer = std.io.fixedBufferStream(&buf).writer();
    const prefix = try std.fmt.allocPrint(g_log_buf_allocator, "[{s}] {s}:{d}: ", .{
        logLevelStr(level), file, line,
    });
    defer g_log_buf_allocator.free(prefix);

    const full = try std.fmt.allocPrint(g_log_buf_allocator, "{s}" ++ fmt ++ "\n", .{ prefix } ++ args);
    defer g_log_buf_allocator.free(full);

    if (!g_log_initialized) {
        const entry = LogEntry{ .line = try g_log_buf_allocator.dupe(u8, full[0 .. full.len - 1]) };
        g_log_buf.append(entry) catch |err| {
            std.debug.print("{s}\n", .{full});
            return;
        };
        return;
    }

    const out = if (g_log_file) |f| f.writer() else std.io.getStdErr().writer();
    _ = out.writeAll(full) catch {};
}

// Shorthand macros equivalent
pub fn LOGE(comptime fmt: []const u8, args: anytype) void {
    logWrite(.error, @src().file, @src().line, fmt, args);
}
pub fn LOGW(comptime fmt: []const u8, args: anytype) void {
    logWrite(.warn, @src().file, @src().line, fmt, args);
}
pub fn LOGI(comptime fmt: []const u8, args: anytype) void {
    logWrite(.info, @src().file, @src().line, fmt, args);
}
pub fn LOGD(comptime fmt: []const u8, args: anytype) void {
    logWrite(.debug, @src().file, @src().line, fmt, args);
}

// --- Path helpers ---
pub fn path_join(allocator: Allocator, buf: *[PATH_MAX]u8, base: []const u8, name: []const u8) ![]const u8 {
    if (name.len == 0) {
        if (base.len >= PATH_MAX) return error.NameTooLong;
        @memcpy(buf[0..base.len], base);
        buf[base.len] = 0;
        return buf[0..base.len];
    }

    const use_slash = if (base.len == 0 or (base.len == 1 and base[0] == '/')) true else base[base.len - 1] != '/';

    const needed = base.len + @as(usize, @intCast(use_slash)) + name.len + 1;
    if (needed > PATH_MAX) return error.NameTooLong;

    var offset: usize = 0;
    @memcpy(buf[offset..][0..base.len], base);
    offset += base.len;

    if (use_slash) {
        buf[offset] = '/';
        offset += 1;
    }

    @memcpy(buf[offset..][0..name.len], name);
    offset += name.len;
    buf[offset] = 0;

    return buf[0..offset];
}

pub fn path_exists(path: []const u8) bool {
    return os.stat(path) catch return false;
}

pub fn path_is_dir(path: []const u8) bool {
    const st = os.stat(path) catch return false;
    return os.S.ISDIR(st.mode);
}

pub fn path_is_symlink(path: []const u8) bool {
    const st = os.lstat(path) catch return false;
    return os.S.ISLNK(st.mode);
}

pub fn mkdir_p(dir: []const u8) !void {
    if (dir.len == 0) return error.InvalidArgument;

    if (path_is_dir(dir)) return;

    var i: usize = 0;
    while (i < dir.len) : (i += 1) {
        if (dir[i] == '/') {
            if (i == 0) continue;
            const part = dir[0..i];
            if (!path_is_dir(part)) {
                os.mkdir(part, 0o755) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            }
        }
    }

    os.mkdir(dir, 0o755) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

// --- Temp dir selection ---
fn is_rw_tmpfs(path: []const u8) bool {
    if (!path_is_dir(path)) return false;

    const statfs = linux.statfs(path) catch return false;
    if (statfs.f_type != TMPFS_MAGIC) return false;

    var tmpl: [PATH_MAX]u8 = undefined;
    const test_path = path_join(std.heap.page_allocator, &tmpl, path, ".magic_mount_testXXXXXX") catch return false;
    defer std.heap.page_allocator.free(test_path);

    const fd = os.mkstemp(tmpl[0..]) catch return false;
    os.close(fd);
    _ = os.unlink(tmpl[0..std.mem.indexOfScalar(u8, &tmpl, 0).?]) catch {};
    return true;
}

pub fn select_auto_tempdir(buf: *[PATH_MAX]u8) []const u8 {
    const candidates = [_][]const u8{ "/mnt/vendor", "/mnt", "/debug_ramdisk" };

    for (candidates) |cand| {
        if (!is_rw_tmpfs(cand)) continue;
        if (path_join(std.heap.page_allocator, buf, cand, ".magic_mount")) |result| {
            LOGI("auto tempdir selected: {s} (from {s})", .{ result, cand });
            return result;
        }
    }

    LOGW("no rw tmpfs found, fallback to {s}", .{DEFAULT_TEMP_DIR});
    @memcpy(buf[0..DEFAULT_TEMP_DIR.len], DEFAULT_TEMP_DIR);
    buf[DEFAULT_TEMP_DIR.len] = 0;
    return buf[0..DEFAULT_TEMP_DIR.len];
}

// --- String utilities ---
pub fn str_trim(str: []u8) []u8 {
    var start: usize = 0;
    while (start < str.len and std.ascii.isWhitespace(str[start])) start += 1;
    if (start == str.len) return str[0..0];

    var end = str.len;
    while (end > start and std.ascii.isWhitespace(str[end - 1])) end -= 1;

    return str[start..end];
}

pub fn str_is_true(str: []const u8) bool {
    const lower = std.ascii.lowerString(str);
    return std.mem.eql(u8, lower, "true") or
           std.mem.eql(u8, lower, "yes") or
           std.mem.eql(u8, lower, "1") or
           std.mem.eql(u8, lower, "on");
}

// --- SELinux xattr ---
pub fn set_selcon(path: []const u8, con: []const u8) !void {
    if (path.len == 0 or con.len == 0) {
        LOGD("set_selcon: skip null args", .{});
        return;
    }

    LOGD("set_selcon({s}, \"{s}\")", .{ path, con });

    try linux.lsetxattr(path, SELINUX_XATTR, con, 0);
}

pub fn get_selcon(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return error.InvalidArgument;

    const size = linux.lgetxattr(path, SELINUX_XATTR, null, 0) catch |err| {
        LOGW("getcon {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    const buf = try allocator.alloc(u8, size + 1);
    const actual = linux.lgetxattr(path, SELINUX_XATTR, buf[0..size], 0) catch |err| {
        allocator.free(buf);
        LOGW("getcon {s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    if (actual != size) {
        allocator.free(buf);
        return error.Unexpected;
    }

    buf[size] = 0;
    LOGD("get_selcon({s}) -> \"{s}\"", .{ path, buf[0..size] });
    return buf[0..size];
}

pub fn copy_selcon(allocator: Allocator, src: []const u8, dst: []const u8) !void {
    if (src.len == 0 or dst.len == 0) {
        LOGD("copy_selcon: skip null args", .{});
        return error.InvalidArgument;
    }

    LOGD("copy_selcon({s} -> {s})", .{ src, dst });

    const con = try get_selcon(allocator, src);
    defer allocator.free(con);
    try set_selcon(dst, con);
}

// --- Permission check ---
pub fn root_check() !void {
    if (os.geteuid() != 0) {
        LOGE("Must run as root (current euid={d})", .{os.geteuid()});
        return error.NotRoot;
    }
}
