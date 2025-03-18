const std = @import("std");
const builtin = @import("builtin");

const build_config = @import("build_config");

pub const semver = std.SemanticVersion.parse(build_config.version) catch @compileError("Given version is not valid semver");

pub const is_debug_build = builtin.mode == std.builtin.OptimizeMode.Debug;

pub var gpa = if (build_config.use_system_allocator) {} else std.heap.GeneralPurposeAllocator(.{
    .safety = is_debug_build,
    .verbose_log = false, // abandon hope all ye who enter here
}){};

pub const allocator = if (build_config.use_system_allocator) std.heap.c_allocator else gpa.allocator();
