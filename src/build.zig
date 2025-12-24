const std = @import("std");
const Builder = std.Build;

// 默认版本
const default_version = "v0.2.2";

pub fn build(b: *Builder) void {
    const target_amd64 = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux },
    });
    const target_arm64 = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .aarch64, .os_tag = .linux },
    });
    const target_armv7 = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .eabihf },
    });

    const optimize = b.standardOptimizeOption(.{});

    // 获取版本字符串（可通过 -Dversion=xxx 覆盖）
    const version = b.option([]const u8, "version", "Project version") orelse default_version;

    // 构建选项：传递 VERSION 宏（在 Zig 中通过 --define）
    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "version", version);

    // 构建函数：为给定目标和优化级别创建可执行文件
    inline for (.{target_amd64, target_arm64, target_armv7}) |target_opt, i| {
        const bin_name = switch (i) {
            0 => "mm_amd64",
            1 => "mm_arm64",
            2 => "mm_armv7",
            else => unreachable,
        };

        const exe = b.addExecutable(.{
            .name = bin_name,
            .root_source_file = b.path("main.zig"),
            .target = target_opt,
            .optimize = optimize,
        });

        // 链接为静态（对 Linux 有效）
        exe.link_libc = false; // 不需要 libc（纯 Zig），若需 libc 则设为 true
        exe.force_static = true;

        // 传入构建选项（如 VERSION）
        exe.root_module.addOptions("build_options", exe_options);

        // 确保输出到 bin/
        const install_step = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .custom = "bin" },
        });

        // 为 release 模式自动 strip
        if (optimize == .ReleaseSmall or optimize == .ReleaseFast) {
            const strip_step = b.addStrip(install_step.artifact);
            strip_step.dest_dir = .{ .custom = "bin" };
            b.getInstallStep().dependOn(&strip_step.step);
        } else {
            b.getInstallStep().dependOn(&install_step.step);
        }

        // 为方便，也可添加别名步骤（可选）
        const alias_step = b.step(bin_name, "Build " ++ bin_name);
        alias_step.dependOn(&install_step.step);
    }

    // 默认：安装所有（等效于 make all）
    const all_step = b.step("all", "Build all targets");
    all_step.dependOn(b.getInstallStep());
}
