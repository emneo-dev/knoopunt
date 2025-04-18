const std = @import("std");

const targets = [_]std.Target.Query{
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    },
    .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    },
    // Currently Windows is disabled because of the odd way I accept connections
    // This will be fixed at some other point in time
    //    .{
    //        .cpu_arch = .x86_64,
    //        .os_tag = .windows,
    //    },
    //    .{
    //        .cpu_arch = .aarch64,
    //        .os_tag = .windows,
    //    },
};

const default_version_string = "0.0.0-dev";

const default_bin_name = "knoopunt";

const build_options = struct {
    version: []const u8,
    build_all: bool,
    bin_name: []const u8,
    use_system_allocator: bool,
    use_llvm: bool,
    optimize: std.builtin.OptimizeMode,
    no_bin: bool,
};

fn add_options_to_bin(b: *std.Build, bin: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, opt: build_options) void {
    const logz_pkg = b.dependency("logz", .{ .target = target, .optimize = opt.optimize });
    const zul_pkg = b.dependency("zul", .{ .target = target, .optimize = opt.optimize });
    const clap_pkg = b.dependency("clap", .{ .target = target, .optimize = opt.optimize });
    const aio_pkg = b.dependency("aio", .{ .target = target, .optimize = opt.optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "version", opt.version);
    options.addOption([]const u8, "bin_name", opt.bin_name);
    options.addOption(bool, "use_system_allocator", opt.use_system_allocator);
    options.addOption(bool, "use_llvm", opt.use_llvm);

    bin.root_module.addOptions("build_config", options);
    bin.root_module.addImport("logz", logz_pkg.module("logz"));
    bin.root_module.addImport("zul", zul_pkg.module("zul"));
    bin.root_module.addImport("clap", clap_pkg.module("clap"));
    bin.root_module.addImport("aio", aio_pkg.module("aio"));
    bin.root_module.addImport("coro", aio_pkg.module("coro"));

    if (opt.use_system_allocator)
        bin.linkLibC();
}

fn create_binary_name(opt: build_options, target: std.Build.ResolvedTarget, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}",
        .{
            opt.bin_name,
            opt.version,
            try target.result.linuxTriple(allocator),
        },
    );
}

fn configure_binary(b: *std.Build, opt: build_options, target: std.Build.ResolvedTarget, simple_bin_name: bool) !*std.Build.Step.Compile {
    const final_bin_name = if (simple_bin_name) opt.bin_name else try create_binary_name(
        opt,
        target,
        b.allocator,
    );
    const bin = b.addExecutable(.{
        .name = final_bin_name,
        .target = target,
        .optimize = opt.optimize,
        .root_source_file = b.path("src/main.zig"),
        .use_llvm = opt.use_llvm,
    });
    add_options_to_bin(b, bin, target, opt);

    if (opt.no_bin) {
        b.getInstallStep().dependOn(&bin.step);
    } else {
        b.installArtifact(bin);
    }

    return bin;
}

fn set_build_options(b: *std.Build) build_options {
    return .{
        .version = b.option(
            []const u8,
            "version",
            "application version string",
        ) orelse default_version_string,
        .build_all = b.option(
            bool,
            "build_all",
            "build on all platforms possible",
        ) orelse false,
        .bin_name = b.option(
            []const u8,
            "bin_name",
            "base bin name",
        ) orelse default_bin_name,
        .use_system_allocator = b.option(
            bool,
            "use_system_allocator",
            "use the system allocator (libc)",
        ) orelse false,
        .use_llvm = b.option(
            bool,
            "use_llvm",
            "use the llvm backend",
        ) orelse true,
        .optimize = b.standardOptimizeOption(.{}),
        .no_bin = b.option(
            bool,
            "no_bin",
            "do not generate a binary",
        ) orelse false,
    };
}

pub fn build(b: *std.Build) !void {
    const native_target = b.standardTargetOptions(.{});

    const opt = set_build_options(b);

    if (!opt.use_llvm and (!native_target.result.cpu.arch.isX86() or opt.build_all)) {
        @panic("You need to activate llvm if you plan to build on something other than x86 (-Duse_llvm)");
    }

    if (opt.build_all) {
        for (targets) |target|
            _ = try configure_binary(
                b,
                opt,
                std.Build.resolveTargetQuery(b, target),
                false,
            );
    } else {
        const native_bin = try configure_binary(
            b,
            opt,
            native_target,
            true,
        );

        const run_native_bin = b.addRunArtifact(native_bin);
        run_native_bin.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_native_bin.addArgs(args);
        }

        const run_step = b.step("run", "Run native binary");
        run_step.dependOn(&run_native_bin.step);
    }
}
