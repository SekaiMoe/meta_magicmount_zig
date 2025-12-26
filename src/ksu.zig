const std = @import("std");
const os = std.os;
const linux = os.linux;
const syscall = linux.syscall6;
const ioctl = linux.ioctl;
const AtomicI32 = std.atomic.Atomic(i32);
const AtomicBool = std.atomic.Atomic(bool);

// --- Constants and Types (from ksu.h) ---
const KSU_INSTALL_MAGIC1: u64 = 0xDEADBEEF;
const KSU_INSTALL_MAGIC2: u64 = 0xCAFEBABE;

const KSU_IOCTL_ADD_TRY_UMOUNT = linux._IO(_IOC_WRITE, 'K', 18, 0);

const KsuAddTryUmountCmd = extern struct {
    arg: u64,   // pointer to const char*
    flags: u32,
    mode: u8,
    pad: [3]u8, // padding to align to 8 bytes (optional but safe)
};

// --- External logging interface (assumed to be implemented elsewhere) ---
extern fn logWrite(level: i32, file: [*:0]const u8, line: c_int, fmt: [*:0]const u8, ...) void;
const LOG_ERROR = 0;
const LOG_WARN = 1;
const LOG_INFO = 2;
const LOG_DEBUG = 3;

inline fn LOG(level: i32, comptime fmt: []const u8, args: anytype) void {
    if (level <= @intFromEnum(g_log_level)) {
        logWrite(level, @ptrCast(@src().file), @intCast(@src().line), fmt, args);
    }
}

// --- Global state ---
var g_driver_fd: AtomicI32 = AtomicI32.init(-1);
var g_driver_fd_initialized: AtomicBool = AtomicBool.init(false);
var g_log_level: i32 = LOG_INFO; // or whatever default you want

// --- Helper: perform KSU install syscall to get fd ---
fn ksuGrabFdOnce() void {
    var fd: i32 = undefined;
    const result = syscall(
        linux.SYS_reboot,
        KSU_INSTALL_MAGIC1,
        KSU_INSTALL_MAGIC2,
        0,
        @ptrToInt(&fd),
        0,
        0,
    );

    if (result != 0) {
        LOG(LOG_WARN, "failed to grab KSU driver fd: {}", .{result});
        g_driver_fd.store(result, .seq_cst);
        return;
    }

    if (fd < 0) {
        LOG(LOG_WARN, "grabbed invalid KSU driver fd: {}", .{fd});
    } else {
        LOG(LOG_DEBUG, "grabbed KSU driver fd: {}", .{fd});
    }

    g_driver_fd.store(fd, .seq_cst);
}

// --- Thread-safe fd getter ---
fn ksuGrabFd() i32 {
    if (!g_driver_fd_initialized.exchange(true, .acq_rel)) {
        ksuGrabFdOnce();
    }
    return g_driver_fd.load(.seq_cst);
}

// --- Main exported function ---
pub export fn ksu_send_unmountable(mntpoint: [*:0]const u8) c_int {
    const fd = ksuGrabFd();
    if (fd < 0) return -1;

    var cmd: KsuAddTryUmountCmd = .{
        .arg = @ptrToInt(mntpoint),
        .flags = 0x2,
        .mode = 1,
        .pad = [_]u8{0} ** 3,
    };

    const rc = ioctl(fd, KSU_IOCTL_ADD_TRY_UMOUNT, @ptrToInt(&cmd));
    if (rc != 0) {
        const errno = @intCast(os.errno(rc));
        LOG(LOG_ERROR, "ioctl KSU_IOCTL_ADD_TRY_UMOUNT failed: {}", .{@errorName(@as(anyerror, @enumFromInt(errno)))});
        return -1;
    }

    return 0;
}
