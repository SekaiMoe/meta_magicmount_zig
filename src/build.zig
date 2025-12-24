const std = @import("std");
const Builder = std.Build;

const default_version = "v0.2.2";

pub fn build(b: *Builder) void {
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Project version") orelse default_version;

    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "version", version);

    const targets = [_]struct {
        name: []const u8,
        query: std.Target.Query,
    }{
        .{ .name = "mm_amd64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "mm_arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .name = "mm_armv7", .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .eabihf } },
    };

    // 创建一个组合步骤来构建所有目标
    const build_all_step = b.step("build-all", "Build all targets (without installing)");

    inline for (targets) |t| {
        const root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.resolveTargetQuery(t.query),
            .optimize = optimize,
        });
        root_module.addOptions("build_options", exe_options);

        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = root_module,
            .linkage = .static,
        });

        // 为每个目标添加安装步骤（这会自动注册到内置的 install 步骤）
        const install_step = b.addInstallArtifact(exe, .{});
        _ = install_step; // 忽略未使用变量警告

        // 创建特定目标的构建步骤（仅构建，不安装）
        
        // 创建特定目标的安装步骤
        const target_install_step = b.step(t.name, "Build and install " ++ t.name);
        target_install_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        // 添加到组合构建步骤
        build_all_step.dependOn(&exe.step);
    }

    // 设置默认步骤为构建所有目标（不安装）
    b.default_step.dependOn(build_all_step);
}
