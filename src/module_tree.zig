const std = @import("std");
const os = std.os;
const linux = os.linux;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// --- External dependencies ---
const MagicMount = @import("magic_mount.zig").MagicMount;
const Utils = @import("utils.zig");

extern fn logWrite(level: i32, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, ...) void;

const LOG_ERROR = 0;
const LOG_WARN = 1;
const LOG_INFO = 2;
const LOG_DEBUG = 3;

inline fn LOG(level: i32, comptime fmt: []const u8, args: anytype) void {
    if (level <= g_log_level) {
        logWrite(level, @src().file, @src().line, fmt, args);
    }
}

var g_log_level: i32 = LOG_INFO;

// --- Constants ---
const DISABLE_FILE_NAME = "disable";
const REMOVE_FILE_NAME = "remove";
const SKIP_MOUNT_FILE_NAME = "skip_mount";

const REPLACE_DIR_XATTR = "trusted.overlay.opaque";
const REPLACE_DIR_FILE_NAME = ".replace";

const DEFAULT_MODULE_DIR = "/data/adb/modules";

const PATH_MAX = 4096;

// --- Node Type ---
pub const NodeFileType = enum {
    REGULAR,
    DIRECTORY,
    SYMLINK,
    WHITEOUT,
};

// --- Node ---
pub const Node = struct {
    name: []u8,
    type: NodeFileType,
    children: ArrayList(*Node),
    module_path: ?[]u8 = null,
    module_name: ?[]u8 = null,
    replace: bool = false,
    skip: bool = false,
    done: bool = false,

    pub fn init(allocator: Allocator, name: []const u8, t: NodeFileType) !*Node {
        const n = try allocator.create(Node);
        n.* = .{
            .name = try allocator.dupe(u8, name),
            .type = t,
            .children = ArrayList(*Node).init(allocator),
        };
        return n;
    }

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit();
        allocator.free(self.name);
        if (self.module_path) |p| allocator.free(p);
        if (self.module_name) |n| allocator.free(n);
    }
};

// --- Node utilities ---
pub fn node_type_from_stat(st: os.Stat) NodeFileType {
    if (os.S.ISCHR(st.mode) and st.rdev == 0) return .WHITEOUT;
    if (os.S.ISREG(st.mode)) return .REGULAR;
    if (os.S.ISDIR(st.mode)) return .DIRECTORY;
    if (os.S.ISLNK(st.mode)) return .SYMLINK;
    return .WHITEOUT;
}

pub fn node_child_find(parent: *Node, name: []const u8) ?*Node {
    for (parent.children.items) |child| {
        if (std.mem.eql(u8, child.name, name)) return child;
    }
    return null;
}

fn node_child_detach(parent: *Node, name: []const u8) ?*Node {
    for (parent.children.items, 0..) |child, i| {
        if (std.mem.eql(u8, child.name, name)) {
            _ = parent.children.swapRemove(i);
            return child;
        }
    }
    return null;
}

// --- Module failure tracking ---
pub fn module_mark_failed(ctx: *MagicMount, allocator: Allocator, module_name: []const u8) !void {
    const failed = ctx.failed_modules orelse return;
    for (failed.items) |m| {
        if (std.mem.eql(u8, m, module_name)) return;
    }
    try failed.append(try allocator.dupe(u8, module_name));
}

// --- Extra partition handling ---
const blacklist = [_][]const u8{
    "bin", "etc", "data", "data_mirror", "sdcard", "tmp", "dev", "sys",
    "mnt", "proc", "d", "test", "product", "vendor", "system_ext", "odm",
};

fn extra_part_blacklisted(name: []const u8) bool {
    if (name.len == 0) return false;
    var n = name;
    if (n[0] == '/') n = n[1..];

    const first_part = std.mem.split(u8, n, "/").first();
    for (blacklist) |b| {
        if (std.mem.eql(u8, first_part, b)) return true;
    }
    return false;
}

pub fn extra_partition_register(ctx: *MagicMount, allocator: Allocator, start: []const u8) !void {
    if (start.len == 0) return;

    var buf = try allocator.dupe(u8, start);
    defer allocator.free(buf);

    std.mem.trim(u8, &buf, " \t\r\n");
    if (buf.len == 0) return;

    if (extra_part_blacklisted(buf)) {
        LOG(LOG_WARN, "extra_partition_register: rejected '{s}' (blacklisted)", .{buf});
        return;
    }

    const extra = ctx.extra_parts orelse return error.InvalidState;
    try extra.append(try allocator.dupe(u8, buf));
    LOG(LOG_INFO, "extra_partition_register: success added '{s}' (total: {} partitions)", .{
        buf, extra.items.len });
}

// --- Directory replace check ---
fn dir_is_replace(path: [*:0]const u8) bool {
    var buf: [8]u8 = undefined;
    const len = linux.lgetxattr(path, REPLACE_DIR_XATTR, &buf, buf.len) catch 0;
    if (len > 0 and len < buf.len) {
        buf[len] = 0;
        if (std.mem.eql(u8, buf[0..len], "y")) return true;
    }

    const fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY, 0) catch return false;
    defer os.close(fd);
    return (os.faccessat(fd, REPLACE_DIR_FILE_NAME, os.F_OK, 0) catch false);
}

// --- Node creation from filesystem ---
fn node_create_from_fs(
    ctx: *MagicMount,
    allocator: Allocator,
    name: []const u8,
    path: [*:0]const u8,
    module_name: ?[]const u8,
) !?*Node {
    const st = os.lstat(path) catch |err| {
        LOG(LOG_DEBUG, "node_create_from_fs: lstat({s}) failed: {s}", .{ path, @errorName(err) });
        return null;
    };

    if (!(os.S.ISCHR(st.mode) or os.S.ISREG(st.mode) or os.S.ISDIR(st.mode) or os.S.ISLNK(st.mode))) {
        LOG(LOG_DEBUG, "node_create_from_fs: skip unsupported file type for {s} (mode={x})", .{ path, st.mode });
        return null;
    }

    const t = node_type_from_stat(st);
    const n = try Node.init(allocator, name, t);

    n.module_path = try allocator.dupe(u8, path);
    if (module_name) |mn| n.module_name = try allocator.dupe(u8, mn);
    n.replace = (t == .DIRECTORY) and dir_is_replace(path);

    LOG(LOG_DEBUG, "node_create_from_fs: created node '{s}' (type={}, replace={}, module={}, path={s})", .{
        name, @intFromEnum(t), n.replace, if (module_name) |mn| mn else "null", path });

    ctx.stats.nodes_total += 1;
    return n;
}

// --- Module disabled check ---
fn module_is_disabled(mod_dir: [*:0]const u8) bool {
    const disable_files = [_][]const u8{ DISABLE_FILE_NAME, REMOVE_FILE_NAME, SKIP_MOUNT_FILE_NAME };
    for (disable_files) |file| {
        var buf: [PATH_MAX]u8 = undefined;
        const p = Utils.path_join(std.heap.page_allocator, &buf, mod_dir, file) catch continue;
        if (Utils.path_exists(p)) return true;
    }
    return false;
}

// --- Recursive directory scan ---
fn node_scan_dir(
    ctx: *MagicMount,
    allocator: Allocator,
    self: *Node,
    dir: [*:0]const u8,
    module_name: ?[]const u8,
    has_any: *bool,
) !void {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();

    var iter = d.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, ".", entry.name) or std.mem.eql(u8, "..", entry.name)) continue;

        var path_buf: [PATH_MAX]u8 = undefined;
        const path = Utils.path_join(allocator, &path_buf, dir, entry.name) catch continue;

        var child = node_child_find(self, entry.name);
        if (child == null) {
            const n = (try node_create_from_fs(ctx, allocator, entry.name, path, module_name)) orelse continue;
            try self.children.append(n);
            child = n;
        }

        if (child) |c| {
            if (c.type == .DIRECTORY) {
                var sub: bool = false;
                try node_scan_dir(ctx, allocator, c, path, module_name, &sub);
                if (sub or c.replace) has_any.* = true;
            } else {
                has_any.* = true;
            }
        }
    }
}

// --- Symlink compatibility ---
fn is_compatible_symlink(
    link_target: []const u8,
    part_name: []const u8,
    ctx: *const MagicMount,
    module_name: ?[]const u8,
) bool {
    var target = link_target;
    while (target.len > 0 and target[target.len - 1] == '/') {
        target = target[0 .. target.len - 1];
    }
    if (target.len == 0) return false;

    const expected_relative = try std.fmt.allocPrint(std.heap.page_allocator, "../{s}", .{part_name});
    defer std.heap.page_allocator.free(expected_relative);
    if (std.mem.eql(u8, target, expected_relative)) return true;

    if (ctx.module_dir and module_name) |mn| {
        var tmp: [PATH_MAX]u8 = undefined;
        const mod_path = Utils.path_join(std.heap.page_allocator, &tmp, ctx.module_dir.?, mn) catch return false;
        const expected_absolute = Utils.path_join(std.heap.page_allocator, &tmp, mod_path, part_name) catch return false;
        if (std.mem.eql(u8, target, expected_absolute)) return true;
    }

    return false;
}

fn find_real_partition_dir(
    ctx: *MagicMount,
    allocator: Allocator,
    part_name: []const u8,
    out_path: *[PATH_MAX]u8,
    out_module: *[]u8,
) !bool {
    var mod_dir = try std.fs.cwd().openDir(ctx.module_dir.?, .{});
    defer mod_dir.close();

    var iter = mod_dir.iterate();
    while (try iter.next()) |mod_entry| {
        if (std.mem.eql(u8, ".", mod_entry.name) or std.mem.eql(u8, "..", mod_entry.name)) continue;

        var mod_path_buf: [PATH_MAX]u8 = undefined;
        const mod_path = Utils.path_join(allocator, &mod_path_buf, ctx.module_dir.?, mod_entry.name) catch continue;
        const st = os.stat(mod_path) catch continue;
        if (!os.S.ISDIR(st.mode)) continue;
        if (module_is_disabled(mod_path)) continue;

        var part_path_buf: [PATH_MAX]u8 = undefined;
        const part_path = Utils.path_join(allocator, &part_path_buf, mod_path, part_name) catch continue;
        if (Utils.path_is_dir(part_path)) {
            @memcpy(out_path[0..part_path.len], part_path);
            out_path[part_path.len] = 0;
            out_module.* = try allocator.dupe(u8, mod_entry.name);
            return true;
        }
    }
    return false;
}

fn symlink_resolve_partition(
    ctx: *MagicMount,
    allocator: Allocator,
    system: *Node,
    part_name: []const u8,
) !void {
    const sys_child = node_child_find(system, part_name) orelse return;
    if (sys_child.type != .SYMLINK or sys_child.module_path == null) return;

    var link_target_buf: [PATH_MAX]u8 = undefined;
    const link_target = os.readlink(sys_child.module_path.?, &link_target_buf) catch return;

    if (!is_compatible_symlink(link_target, part_name, ctx, sys_child.module_name)) return;

    var real_part_path: [PATH_MAX]u8 = undefined;
    var module_name: []u8 = undefined;
    const found = find_real_partition_dir(ctx, allocator, part_name, &real_part_path, &module_name) catch return;
    if (!found) return;

    const new_part = try Node.init(allocator, part_name, .DIRECTORY);
    var part_has_any: bool = false;
    try node_scan_dir(ctx, allocator, new_part, real_part_path[0..std.mem.indexOfScalar(u8, &real_part_path, 0).?], module_name, &part_has_any);

    if (!part_has_any) {
        new_part.deinit(allocator);
        allocator.destroy(new_part);
        return;
    }

    _ = node_child_detach(system, part_name);
    new_part.module_name = module_name;
    try system.children.append(new_part);
    LOG(LOG_INFO, "replaced symlink with directory node: {s} (from module '{s}')", .{ part_name, module_name });
}

fn symlink_resolve_all_partition_links(ctx: *MagicMount, allocator: Allocator, system: *Node) !void {
    const builtin_parts = [_][]const u8{ "vendor", "system_ext", "product", "odm" };
    for (builtin_parts) |part| {
        try symlink_resolve_partition(ctx, allocator, system, part);
    }

    const extra = ctx.extra_parts orelse return;
    for (extra.items) |part| {
        try symlink_resolve_partition(ctx, allocator, system, part);
    }
}

// --- Partition scan from modules ---
fn partition_scan_from_modules(
    ctx: *MagicMount,
    allocator: Allocator,
    part_name: []const u8,
    parent_node: *Node,
) !bool {
    var mod_dir = try std.fs.cwd().openDir(ctx.module_dir.?, .{});
    defer mod_dir.close();

    var has_any = false;
    var iter = mod_dir.iterate();
    while (try iter.next()) |mod_entry| {
        if (std.mem.eql(u8, ".", mod_entry.name) or std.mem.eql(u8, "..", mod_entry.name)) continue;

        var mod_path_buf: [PATH_MAX]u8 = undefined;
        const mod_path = Utils.path_join(allocator, &mod_path_buf, ctx.module_dir.?, mod_entry.name) catch continue;
        const st = os.stat(mod_path) catch continue;
        if (!os.S.ISDIR(st.mode)) continue;
        if (module_is_disabled(mod_path)) continue;

        var part_path_buf: [PATH_MAX]u8 = undefined;
        const part_path = Utils.path_join(allocator, &part_path_buf, mod_path, part_name) catch continue;
        if (!Utils.path_is_dir(part_path)) continue;

        var sub: bool = false;
        try node_scan_dir(ctx, allocator, parent_node, part_path, mod_entry.name, &sub);
        if (sub) has_any = true;
    }
    return has_any;
}

// --- Partition promotion ---
fn partition_promote_to_root(
    root: *Node,
    system: *Node,
    part_name: []const u8,
    need_symlink: bool,
) !void {
    var rp_buf: [PATH_MAX]u8 = undefined;
    const rp = Utils.path_join(std.heap.page_allocator, &rp_buf, "/", part_name) catch return;
    if (!Utils.path_is_dir(rp)) return;

    if (need_symlink) {
        var sp_buf: [PATH_MAX]u8 = undefined;
        const sp = Utils.path_join(std.heap.page_allocator, &sp_buf, "/system", part_name) catch return;
        if (!Utils.path_is_symlink(sp)) return;
    }

    const child = node_child_detach(system, part_name) orelse return;
    try root.children.append(child);
    LOG(LOG_DEBUG, "promoting '{s}' from /system to /", .{part_name});
}

// --- Main tree builder ---
pub fn build_mount_tree(ctx: *MagicMount, allocator: Allocator) !?*Node {
    const mdir = ctx.module_dir orelse DEFAULT_MODULE_DIR;

    LOG(LOG_INFO, "build_mount_tree: module_dir={s}", .{mdir});

    var root = try Node.init(allocator, "", .DIRECTORY);
    var system = try Node.init(allocator, "system", .DIRECTORY);
    defer {
        if (build_mount_tree) {
            // Only deinit if we return null
        }
    }

    var mod_dir = try std.fs.cwd().openDir(mdir.*, .{});
    defer mod_dir.close();

    var has_any = false;
    var iter = mod_dir.iterate();
    while (try iter.next()) |mod_entry| {
        if (std.mem.eql(u8, ".", mod_entry.name) or std.mem.eql(u8, "..", mod_entry.name)) continue;

        var mod_path_buf: [PATH_MAX]u8 = undefined;
        const mod_path = Utils.path_join(allocator, &mod_path_buf, mdir.*, mod_entry.name) catch |err| {
            LOG(LOG_ERROR, "build_mount_tree: path_join failed: {s}", .{@errorName(err)});
            return err;
        };

        const st = os.stat(mod_path) catch continue;
        if (!os.S.ISDIR(st.mode)) continue;
        if (module_is_disabled(mod_path)) continue;

        var mod_sys_buf: [PATH_MAX]u8 = undefined;
        const mod_sys = Utils.path_join(allocator, &mod_sys_buf, mod_path, "system") catch |err| {
            LOG(LOG_ERROR, "build_mount_tree: path_join system failed: {s}", .{@errorName(err)});
            return err;
        };

        if (!Utils.path_is_dir(mod_sys)) continue;

        LOG(LOG_INFO, "build_mount_tree: collecting module {s}", .{mod_entry.name});
        ctx.stats.modules_total += 1;

        var sub: bool = false;
        try node_scan_dir(ctx, allocator, system, mod_sys, mod_entry.name, &sub);
        if (sub) has_any = true;
    }

    if (!has_any) {
        root.deinit(allocator);
        allocator.destroy(root);
        system.deinit(allocator);
        allocator.destroy(system);
        return null;
    }

    ctx.stats.nodes_total += 2;

    try symlink_resolve_all_partition_links(ctx, allocator, system);

    const BuiltinPart = struct { name: []const u8, need_symlink: bool };
    const builtin_parts = [_]BuiltinPart{
        .{ .name = "vendor", .need_symlink = true },
        .{ .name = "system_ext", .need_symlink = true },
        .{ .name = "product", .need_symlink = true },
        .{ .name = "odm", .need_symlink = false },
    };

    for (builtin_parts) |bp| {
        try partition_promote_to_root(root, system, bp.name, bp.need_symlink);
    }

    const extra = ctx.extra_parts orelse {};
    for (extra.items) |name| {
        var rp_buf: [PATH_MAX]u8 = undefined;
        const rp = Utils.path_join(allocator, &rp_buf, "/", name) catch continue;
        if (!Utils.path_is_dir(rp)) continue;

        const child = try Node.init(allocator, name, .DIRECTORY);
        const has_content = try partition_scan_from_modules(ctx, allocator, name, child);
        if (has_content) {
            try root.children.append(child);
        } else {
            child.deinit(allocator);
            allocator.destroy(child);
        }
    }

    try root.children.append(system);

    LOG(LOG_INFO, "build_mount_tree: root tree successfully built", .{});
    return root;
}

// --- Cleanup ---
pub fn module_tree_cleanup(ctx: *MagicMount, allocator: Allocator) void {
    if (ctx.failed_modules) |arr| {
        for (arr.items) |s| allocator.free(s);
        arr.deinit();
    }
    if (ctx.extra_parts) |arr| {
        for (arr.items) |s| allocator.free(s);
        arr.deinit();
    }
}
