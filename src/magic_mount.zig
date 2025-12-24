const std = @import("std");
const os = std.os;
const linux = os.linux;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// --- External dependencies (assumed to be defined elsewhere in Zig) ---
const Ksu = @import("ksu.zig");
const ModuleTree = @import("module_tree.zig");
const Utils = @import("utils.zig");

extern fn logWrite(level: i32, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, ...) void;

const LOG_ERROR = 0;
const LOG_WARN = 1;
const LOG_INFO = 2;
const LOG_DEBUG = 3;

inline fn LOG(level: i32, comptime fmt: []const u8, args: anytype) void {
    if (level <= g_log_level) {
        logWrite(level, @ptrCast(@src().file), @intCast(@src().line), fmt, args...);
    }
}

var g_log_level: i32 = LOG_INFO;

// --- Constants ---
const DISABLE_FILE_NAME = "disable";
const REMOVE_FILE_NAME = "remove";
const SKIP_MOUNT_FILE_NAME = "skip_mount";

const REPLACE_DIR_XATTR = "trusted.overlay.opaque";
const REPLACE_DIR_FILE_NAME = ".replace";

const DEFAULT_MOUNT_SOURCE = "KSU";
const DEFAULT_MODULE_DIR = "/data/adb/modules";
const DEFAULT_TEMP_DIR = "/dev/.magic_mount";

const PATH_MAX = 4096;

// --- Types ---
pub const MountStats = extern struct {
    modules_total: i32,
    nodes_total: i32,
    nodes_mounted: i32,
    nodes_skipped: i32,
    nodes_whiteout: i32,
    nodes_fail: i32,
};

pub const MagicMount = extern struct {
    module_dir: [*:0]const u8,
    mount_source: [*:0]const u8,

    stats: MountStats,

    failed_modules: [*] [*:0]u8,
    failed_modules_count: i32,

    extra_parts: [*] [*:0]u8,
    extra_parts_count: i32,

    enable_unmountable: bool,
};

// --- Initialization ---
pub fn magic_mount_init(ctx: *MagicMount) void {
    if (ctx == null) return;
    @memset(ctx.*, 0);
    ctx.module_dir = DEFAULT_MODULE_DIR;
    ctx.mount_source = DEFAULT_MOUNT_SOURCE;
    ctx.enable_unmountable = true;
}

// --- Cleanup ---
pub fn magic_mount_cleanup(ctx: *MagicMount) void {
    if (ctx == null) return;
    ModuleTree.module_tree_cleanup(ctx);
}

// --- Forward declarations ---
fn mm_clone_symlink(allocator: Allocator, src: [*:0]const u8, dst: [*:0]const u8) !void;
fn mm_mirror_entry(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, work: [*:0]const u8, name: [*:0]const u8) !void;
fn mm_apply_node_recursive(ctx: *MagicMount, allocator: Allocator, base: [*:0]const u8, wbase: [*:0]const u8, node: *ModuleTree.Node, has_tmpfs: bool) !void;
fn mm_check_need_tmpfs(node: *ModuleTree.Node, path: [*:0]const u8) bool;
fn mm_setup_dir_tmpfs(path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node) !void;
fn mm_process_dir_children(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, now_tmp: bool) !void;
fn mm_process_remaining_children(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, now_tmp: bool) !void;
fn mm_apply_regular_file(ctx: *MagicMount, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, has_tmpfs: bool) !void;
fn mm_apply_symlink(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node) !void;

// --- Clone symlink ---
fn mm_clone_symlink(allocator: Allocator, src: [*:0]const u8, dst: [*:0]const u8) !void {
    var target_buf: [PATH_MAX]u8 = undefined;
    const target = target_buf[0..];

    const len = try os.readlink(src, target);
    const target_z = target[0..len] ++ [_]u8{0};

    try os.symlink(target_z.ptr, dst);
    _ = Utils.copy_selcon(src, dst); // ignore error

    LOG(LOG_DEBUG, "clone symlink {s} -> {s} ({s})", .{ src, dst, target_z.ptr });
}

// --- Mirror directory entry (for tmpfs overlay of original content) ---
fn mm_mirror_entry(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, work: [*:0]const u8, name: [*:0]const u8) !void {
    var src_buf: [PATH_MAX]u8 = undefined;
    var dst_buf: [PATH_MAX]u8 = undefined;
    const src = Utils.path_join(allocator, &src_buf, path, name) catch return;
    const dst = Utils.path_join(allocator, &dst_buf, work, name) catch return;

    const st = os.lstat(src) catch |err| {
        LOG(LOG_WARN, "lstat {s}: {s}", .{ src, @errorName(err) });
        return;
    };

    if (os.S.ISREG(st.mode)) {
        const fd = try os.open(dst, .{ .mode = st.mode & 0o7777 });
        os.close(fd);

        try linux.mount(src, dst, null, linux.MS_BIND, null);
    } else if (os.S.ISDIR(st.mode)) {
        _ = os.mkdir(dst, st.mode & 0o7777) catch |err| {
            if (err != error.PathAlreadyExists) return error.DirectoryCreationFailed;
        };
        os.chmod(dst, st.mode & 0o7777) catch {};
        os.chown(dst, st.uid, st.gid) catch {};

        _ = Utils.copy_selcon(src, dst);

        var dir = try std.fs.cwd().openDir(src, .{});
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            try mm_mirror_entry(ctx, allocator, src, dst, entry.name.ptr);
        }
    } else if (os.S.ISLNK(st.mode)) {
        try mm_clone_symlink(allocator, src, dst);
    }
}

// --- Apply regular file (from module) ---
fn mm_apply_regular_file(ctx: *MagicMount, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, has_tmpfs: bool) !void {
    const target = if (has_tmpfs) wpath else path;

    if (has_tmpfs) {
        const last_slash = std.mem.lastIndexOfScalar(u8, wpath[0..std.mem.indexOfScalar(u8, wpath, 0).?], '/') orelse return;
        const parent = wpath[0..last_slash];
        try Utils.mkdir_p(parent);

        const fd = try os.open(wpath, .{ .mode = 0o644 });
        os.close(fd);
    }

    if (node.module_path == null) {
        LOG(LOG_ERROR, "no module file for {s}", .{path});
        return error.InvalidArgument;
    }

    LOG(LOG_DEBUG, "bind {s} -> {s}", .{ node.module_path.?, target });

    try linux.mount(node.module_path.?, target, null, linux.MS_BIND, null);

    // Report to KSU if not in workdir
    if (!std.mem.containsAtLeast(u8, target, 0, ".magic_mount/workdir/", 1)) {
        if (ctx.enable_unmountable) {
            _ = Ksu.ksu_send_unmountable(path);
        }
    }

    _ = linux.mount(null, target, null, linux.MS_REMOUNT | linux.MS_BIND | linux.MS_RDONLY, null) catch {};

    ctx.stats.nodes_mounted += 1;
}

// --- Apply symlink from module ---
fn mm_apply_symlink(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node) !void {
    if (node.module_path == null) {
        LOG(LOG_ERROR, "no module symlink for {s}", .{path});
        return error.InvalidArgument;
    }

    try mm_clone_symlink(allocator, node.module_path.?, wpath);
    ctx.stats.nodes_mounted += 1;
}

// --- Check if tmpfs is needed for a directory ---
fn mm_check_need_tmpfs(node: *ModuleTree.Node, path: [*:0]const u8) bool {
    for (node.children.items) |child| {
        var rp_buf: [PATH_MAX]u8 = undefined;
        const rp = Utils.path_join(std.heap.page_allocator, &rp_buf, path, child.name) catch continue;

        var need = false;

        if (child.type == .SYMLINK) {
            need = true;
        } else if (child.type == .WHITEOUT) {
            need = Utils.path_exists(rp);
        } else {
            const st = os.lstat(rp) catch {
                need = true;
                continue;
            };
            const rt = ModuleTree.node_type_from_stat(st);
            if (rt != child.type or rt == .SYMLINK) need = true;
        }

        if (need and node.module_path == null) {
            LOG(LOG_ERROR, "cannot create tmpfs on {s} ({s}) - child type: {}, target exists: {}", .{
                path, child.name, @intFromEnum(child.type), Utils.path_exists(rp) });
            child.skip = true;
            continue;
        }

        if (need) return true;
    }
    return false;
}

// --- Set up tmpfs dir with metadata ---
fn mm_setup_dir_tmpfs(path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node) !void {
    try Utils.mkdir_p(wpath);

    const st = os.stat(path) catch |err1| {
        if (node.module_path) |mp| {
            os.stat(mp) catch {
                LOG(LOG_ERROR, "no dir meta for {s}", .{path});
                return err1;
            };
        } else {
            LOG(LOG_ERROR, "no dir meta for {s}", .{path});
            return err1;
        }
    } else {
        os.chmod(wpath, st.mode & 0o7777) catch {};
        os.chown(wpath, st.uid, st.gid) catch {};
        _ = Utils.copy_selcon(path, wpath);
    };
}

// --- Process existing children in original dir ---
fn mm_process_dir_children(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, now_tmp: bool) !void {
    if (!Utils.path_exists(path) or node.replace) return;

    var dir = std.fs.cwd().openDir(path, .{}) catch |err| {
        if (!now_tmp) return;
        LOG(LOG_ERROR, "opendir {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

        const child = ModuleTree.node_child_find(node, entry.name.ptr);
        if (child) |c| {
            if (c.skip) {
                c.done = true;
                continue;
            }
            c.done = true;
            mm_apply_node_recursive(ctx, allocator, path, wpath, c, now_tmp) catch |err| {
                const mn = if (c.module_name) |mn| mn else if (node.module_name) |mn| mn else null;
                if (mn) |name| {
                    LOG(LOG_ERROR, "child {s}/{s} failed (module: {s})", .{ path, c.name, name });
                    ModuleTree.module_mark_failed(ctx, name);
                } else {
                    LOG(LOG_ERROR, "child {s}/{s} failed (no module_name)", .{ path, c.name });
                }
                ctx.stats.nodes_fail += 1;
                if (now_tmp) return err;
            };
        } else if (now_tmp) {
            mm_mirror_entry(ctx, allocator, path, wpath, entry.name.ptr) catch {};
        }
    }
}

// --- Process remaining (module-only) children ---
fn mm_process_remaining_children(ctx: *MagicMount, allocator: Allocator, path: [*:0]const u8, wpath: [*:0]const u8, node: *ModuleTree.Node, now_tmp: bool) !void {
    for (node.children.items) |child| {
        if (child.skip or child.done) continue;
        mm_apply_node_recursive(ctx, allocator, path, wpath, child, now_tmp) catch |err| {
            const mn = if (child.module_name) |mn| mn else if (node.module_name) |mn| mn else null;
            if (mn) |name| {
                LOG(LOG_ERROR, "child {s}/{s} failed (module: {s})", .{ path, child.name, name });
                ModuleTree.module_mark_failed(ctx, name);
            } else {
                LOG(LOG_ERROR, "child {s}/{s} failed (no module_name)", .{ path, child.name });
            }
            ctx.stats.nodes_fail += 1;
            if (now_tmp) return err;
        };
    }
}

// --- Recursive node application ---
fn mm_apply_node_recursive(ctx: *MagicMount, allocator: Allocator, base: [*:0]const u8, wbase: [*:0]const u8, node: *ModuleTree.Node, has_tmpfs: bool) !void {
    var path_buf: [PATH_MAX]u8 = undefined;
    var wpath_buf: [PATH_MAX]u8 = undefined;
    const path = Utils.path_join(allocator, &path_buf, base, node.name) catch return;
    const wpath = Utils.path_join(allocator, &wpath_buf, wbase, node.name) catch return;

    switch (node.type) {
        .REGULAR => try mm_apply_regular_file(ctx, path, wpath, node, has_tmpfs),
        .SYMLINK => try mm_apply_symlink(ctx, allocator, path, wpath, node),
        .WHITEOUT => {
            LOG(LOG_DEBUG, "whiteout {s}", .{path});
            ctx.stats.nodes_whiteout += 1;
        },
        .DIRECTORY => {
            var create_tmp = (!has_tmpfs and node.replace and node.module_path != null);
            if (!has_tmpfs and !create_tmp) {
                create_tmp = mm_check_need_tmpfs(node, path);
            }
            const now_tmp = has_tmpfs or create_tmp;

            if (now_tmp) try mm_setup_dir_tmpfs(path, wpath, node);

            if (create_tmp) {
                try linux.mount(wpath, wpath, null, linux.MS_BIND, null);
            }

            try mm_process_dir_children(ctx, allocator, path, wpath, node, now_tmp);
            try mm_process_remaining_children(ctx, allocator, path, wpath, node, now_tmp);

            if (create_tmp) {
                _ = linux.mount(null, wpath, null, linux.MS_REMOUNT | linux.MS_BIND | linux.MS_RDONLY, null) catch {};

                try linux.mount(wpath, path, null, linux.MS_MOVE, null);
                LOG(LOG_INFO, "move mountpoint success: {s} -> {s}", .{ wpath, path });
                _ = linux.mount(null, path, null, linux.MS_REC | linux.MS_PRIVATE, null) catch {};

                if (ctx.enable_unmountable) {
                    _ = Ksu.ksu_send_unmountable(path);
                }
            }
            ctx.stats.nodes_mounted += 1;
        },
    }
}

// --- Main entry point ---
pub fn magic_mount(ctx: *MagicMount, tmp_root: [*:0]const u8, allocator: Allocator) !i32 {
    if (ctx == null) return -1;

    const root = ModuleTree.build_mount_tree(ctx) orelse {
        LOG(LOG_INFO, "no modules, magic_mount skipped", .{});
        return 0;
    };
    defer ModuleTree.node_free(root);

    var tmp_dir_buf: [PATH_MAX]u8 = undefined;
    const tmp_dir = Utils.path_join(allocator, &tmp_dir_buf, tmp_root, "workdir") catch return -1;

    try Utils.mkdir_p(tmp_dir);

    LOG(LOG_INFO, "starting magic_mount core logic: tmpfs_source={s} tmp_dir={s}", .{ ctx.mount_source, tmp_dir });

    try linux.mount(ctx.mount_source, tmp_dir, "tmpfs", 0, "");
    _ = linux.mount(null, tmp_dir, null, linux.MS_REC | linux.MS_PRIVATE, null) catch {};

    var rc: i32 = 0;
    mm_apply_node_recursive(ctx, allocator, "/", tmp_dir, root, false) catch |err| {
        LOG(.{}, "mm_apply_node_recursive failed: {}", .{@errorName(err)});
        ctx.stats.nodes_fail += 1;
        rc = -1;
    };

    _ = linux.umount2(tmp_dir, linux.MNT_DETACH) catch |err| {
        LOG(LOG_ERROR, "umount {s}: {s}", .{ tmp_dir, @errorName(err) });
    };

    _ = os.rmdir(tmp_dir) catch {};

    return rc;
}

// Allow C linkage if needed
pub export fn c_magic_mount(ctx: *MagicMount, tmp_root: [*:0]const u8) c_int {
    const rc = magic_mount(ctx, tmp_root, std.heap.page_allocator) catch return -1;
    return @intCast(rc);
}
