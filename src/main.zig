const std = @import("std");
const os = std.os;
const Allocator = std.mem.Allocator;

const MagicMount = @import("magic_mount.zig");
const ModuleTree = @import("module_tree.zig");
const Utils = @import("utils.zig");

const VERSION = "1.0.0"; // Replace with your version or @embedFile("VERSION")

const Config = struct {
    module_dir: ?[]const u8 = null,
    temp_dir: ?[]const u8 = null,
    mount_source: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    partitions: ?[]const u8 = null,
    debug: bool = false,
    umount: bool = true,
};

fn usage(prog: []const u8) void {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.print(
        \\Magic Mount: {s}
        \\
        \\Usage: {s} [options]
        \\
        \\Options:
        \\  -m, --module-dir DIR      Module directory (default: {s})
        \\  -t, --temp-dir DIR        Temporary directory (default: auto-detected)
        \\  -s, --mount-source SRC    Mount source (default: {s})
        \\  -p, --partitions LIST     Extra partitions (eg. mi_ext,my_stock)
        \\  -l, --log-file FILE       Log file (default: stderr, '-' for stdout)
        \\  -c, --config FILE         Config file (default: {s})
        \\  -v, --verbose             Enable debug logging
        \\      --no-umount           Disable umount
        \\  -h, --help                Show this help message
        \\
    , .{
        VERSION,
        prog,
        MagicMount.DEFAULT_MODULE_DIR,
        MagicMount.DEFAULT_MOUNT_SOURCE,
        "/data/adb/magic_mount/mm.conf",
    }) catch {};
}

fn load_config_file(allocator: Allocator, path: []const u8, cfg: *Config, _ctx: *MagicMount.MagicMount) !void {
    _ = _ctx;
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            Utils.LOGW("config file {s}: {s}", .{ path, @errorName(err) });
        }
        return;
    };
    defer file.close();

    Utils.LOGI("Loading config file: {s}", .{path});

    var buf: [1024]u8 = undefined;
    var line_num: usize = 0;

    var stream = std.io.bufferedReader(file.reader());
    var reader = stream.reader();

    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        line_num += 1;

        var trimmed = Utils.str_trim(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            Utils.LOGW("config:{d}: invalid line (no '=')", .{line_num});
            continue;
        };

        const key = Utils.str_trim(trimmed[0..eq_index]);
        const val = Utils.str_trim(trimmed[eq_index + 1 ..]);

        if (key.len == 0 or val.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(key, "module_dir")) {
            cfg.module_dir = try allocator.dupe(u8, val);
        } else if (std.ascii.eqlIgnoreCase(key, "temp_dir")) {
            cfg.temp_dir = try allocator.dupe(u8, val);
        } else if (std.ascii.eqlIgnoreCase(key, "mount_source")) {
            cfg.mount_source = try allocator.dupe(u8, val);
        } else if (std.ascii.eqlIgnoreCase(key, "log_file")) {
            cfg.log_file = try allocator.dupe(u8, val);
        } else if (std.ascii.eqlIgnoreCase(key, "debug")) {
            cfg.debug = Utils.str_is_true(val);
        } else if (std.ascii.eqlIgnoreCase(key, "umount")) {
            cfg.umount = Utils.str_is_true(val);
        } else if (std.ascii.eqlIgnoreCase(key, "partitions")) {
            cfg.partitions = try allocator.dupe(u8, val);
        } else {
            Utils.LOGW("config:{d}: unknown key '{s}'", .{ line_num, key });
        }
    }
}

fn parse_partitions(allocator: Allocator, list: []const u8, ctx: *MagicMount.MagicMount) !void {
    if (list.len == 0) return;

    var p: usize = 0;
    while (p < list.len) : (p += 1) {
        while (p < list.len and (list[p] == ',' or std.ascii.isWhitespace(list[p]))) p += 1;
        if (p >= list.len) break;

        const start = p;
        while (p < list.len and list[p] != ',' and !std.ascii.isWhitespace(list[p])) p += 1;
        const token = list[start..p];
        if (token.len > 0) {
            try ModuleTree.extra_partition_register(ctx, allocator, token);
            Utils.LOGD("Added extra partition: {s}", .{token});
        }
    }
}

fn setup_logging(_allocator: Allocator, log_path: []const u8) !?std.fs.File {
    _ = _allocator;
    if (std.mem.eql(u8, log_path, "-")) {
        return null; // Use stdout (handled by logSetFile(null))
    }

    const file = std.fs.cwd().openFile(log_path, .{ .mode = .append }) catch |err| {
        std.debug.print("Error: Cannot open log file {s}: {s}\n", .{ log_path, @errorName(err) });
        return err;
    };
    return file;
}

fn print_summary(ctx: *const MagicMount.MagicMount) void {
    Utils.LOGI("Summary", .{});
    Utils.LOGI("Modules processed:     {d}", .{ctx.stats.modules_total});
    Utils.LOGI("Nodes total:           {d}", .{ctx.stats.nodes_total});
    Utils.LOGI("Nodes mounted:         {d}", .{ctx.stats.nodes_mounted});
    Utils.LOGI("Nodes skipped:         {d}", .{ctx.stats.nodes_skipped});
    Utils.LOGI("Whiteouts:             {d}", .{ctx.stats.nodes_whiteout});
    Utils.LOGI("Failures:              {d}", .{ctx.stats.nodes_fail});

    const failed = ctx.failed_modules orelse {
        Utils.LOGI("No module failures", .{});
        return;
    };

    if (failed.items.len > 0) {
        Utils.LOGE("Failed modules ({d}):", .{failed.items.len});
        for (failed.items) |mod| {
            Utils.LOGE("  - {s}", .{mod});
        }
    } else {
        Utils.LOGI("No module failures", .{});
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize logging early
    Utils.logInit(allocator);

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const prog = if (args.len > 0) args[0] else "magic_mount";

    var ctx: MagicMount.MagicMount = .{
        .module_dir = null,
        .mount_source = null,
        .stats = .{},
        .failed_modules = null,
        .extra_parts = null,
        .enable_unmountable = true,
    };
    MagicMount.magic_mount_init(&ctx);

    // Initialize string lists
    ctx.failed_modules = std.ArrayList([]u8).init(allocator);
    ctx.extra_parts = std.ArrayList([]u8).init(allocator);
    defer ModuleTree.module_tree_cleanup(&ctx, allocator);

    var cfg: Config = .{ .umount = true };
    var auto_tmp: [Utils.PATH_MAX]u8 = [_]u8{0} ** Utils.PATH_MAX;
    var tmp_dir: ?[]const u8 = null;
    var cli_log_path: ?[]const u8 = null;
    var cli_has_partitions = false;
    var config_path: []const u8 = "/data/adb/magic_mount/mm.conf";

    // First pass: get config path and log file
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) and i + 1 < args.len) {
            config_path = args[i + 1];
            i += 2;
            continue;
        }
        if ((std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--log-file")) and i + 1 < args.len) {
            cli_log_path = args[i + 1];
            i += 2;
            continue;
        }
        i += 1;
    }

    // Setup CLI log file
    if (cli_log_path) |path| {
        const log_file = try setup_logging(allocator, path);
        Utils.logSetFile(log_file);
    }

    // Load config
    try load_config_file(allocator, config_path, &cfg, &ctx);

    // Setup config log file (if no CLI override)
    if (cli_log_path == null and cfg.log_file) |path| {
        const log_file = try setup_logging(allocator, path);
        Utils.logSetFile(log_file);
    }

    // Apply config defaults
    if (cfg.module_dir) ctx.module_dir = cfg.module_dir;
    if (cfg.mount_source) ctx.mount_source = cfg.mount_source;
    if (cfg.temp_dir) tmp_dir = cfg.temp_dir;
    if (cfg.debug) Utils.logSetLevel(.debug);
    ctx.enable_unmountable = cfg.umount;

    // Second pass: handle all args
    var j: usize = 1;
    while (j < args.len) : (j += 1) {
        const arg = args[j];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(prog);
            return 0;
        }

        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            Utils.logSetLevel(.debug);
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-umount")) {
            ctx.enable_unmountable = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config") or
            std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--log-file"))
        {
            j += 1;
            continue;
        }

        if ((std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--module-dir"))) {
            if (j + 1 >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                usage(prog);
                return error.MissingArgument;
            }
            j += 1;
            ctx.module_dir = args[j];
            continue;
        }

        if ((std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--temp-dir"))) {
            if (j + 1 >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                usage(prog);
                return error.MissingArgument;
            }
            j += 1;
            tmp_dir = args[j];
            continue;
        }

        if ((std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--mount-source"))) {
            if (j + 1 >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                usage(prog);
                return error.MissingArgument;
            }
            j += 1;
            ctx.mount_source = args[j];
            continue;
        }

        if ((std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--partitions"))) {
            cli_has_partitions = true;
            if (j + 1 >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                usage(prog);
                return error.MissingArgument;
            }
            j += 1;
            const partitions = args[j];
            try parse_partitions(allocator, partitions, &ctx);
            continue;
        }

        std.debug.print("Error: Unknown argument: {s}\n\n", .{arg});
        usage(prog);
        return 1;
    }

    // Handle partitions from config if not provided via CLI
    if (!cli_has_partitions and cfg.partitions) |list| {
        try parse_partitions(allocator, list, &ctx);
    }

    // Determine temp directory
    if (tmp_dir == null) {
        const selected = Utils.select_auto_tempdir(&auto_tmp);
        if (selected.len == 0) {
            Utils.LOGE("failed to determine temp directory", .{});
            return 1;
        }
        tmp_dir = selected;
    }

    // Root check
    try Utils.root_check();

    // Log startup info
    Utils.LOGI("Magic Mount {s} Starting", .{VERSION});
    Utils.LOGI("Configuration:", .{});
    Utils.LOGI("  Module directory:  {s}", .{ctx.module_dir orelse MagicMount.DEFAULT_MODULE_DIR});
    Utils.LOGI("  Temp directory:    {s}", .{tmp_dir.?});
    Utils.LOGI("  Mount source:      {s}", .{ctx.mount_source orelse MagicMount.DEFAULT_MOUNT_SOURCE});
    Utils.LOGI("  Log level:         {s}", .{if (@intFromEnum(Utils.g_log_level) >= @intFromEnum(Utils.LogLevel.debug)) "DEBUG" else "INFO"});

    if ((ctx.extra_parts orelse .{}).items.len > 0) {
        Utils.LOGI("  Extra partitions:  {d}", .{(ctx.extra_parts.?).items.len});
        for ((ctx.extra_parts.?).items) |part| {
            Utils.LOGI("    - {s}", .{part});
        }
    }

    // Run magic_mount
    const rc = MagicMount.magic_mount(&ctx, tmp_dir.?, allocator) catch |err| {
        Utils.LOGE("magic_mount failed: {s}", .{@errorName(err)});
        return 1;
    };

    // Print results
    if (rc == 0) {
        Utils.LOGI("Magic Mount Completed Successfully", .{});
    } else {
        Utils.LOGE("Magic Mount Failed (rc={d})", .{rc});
    }

    print_summary(&ctx);

    return if (rc == 0) 0 else 1;
}
