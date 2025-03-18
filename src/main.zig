const std = @import("std");
const builtin = @import("builtin");

const logz = @import("logz");
const zul = @import("zul");
const clap = @import("clap");
const coro = @import("coro");

const build_config = @import("build_config");

const utils = @import("utils.zig");
const options = @import("options.zig");
const app = @import("app.zig");

const args =
    \\    -h, --help                 Display this help and exit
    \\    -d, --debug                Enable debug mode (false)
    \\    -a, --address      <str>   Server address (127.0.0.1)
    \\    -p, --port         <u16>   Server port (2105)
    \\    -P, --client_port  <u16>   Client port (2105)
    \\    -m, --min_buf_time <usize> Min time to wait before relaying data in ms (1)
    \\    -M, --max_buf_time <usize> Max time to wait before relaying data in ms (50)
    \\
;

pub fn main() !void {
    const start_time = std.time.milliTimestamp();

    defer {
        // Don't panic in release builds, that should only be needed in debug
        if (!build_config.use_system_allocator) {
            if (utils.gpa.deinit() != .ok and utils.is_debug_build)
                @panic("memory leaked");
        }
    }

    const params = comptime clap.parseParamsComptime(args);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = utils.allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var opt = options{};

    if (res.args.help != 0) {
        try std.io.getStdOut().writeAll(build_config.bin_name ++ " " ++ build_config.version ++ ":\n" ++ args);
        return;
    }

    if (res.args.debug != 0)
        opt.debug = true;
    if (res.args.address) |address|
        opt.address = address;
    if (res.args.port) |port|
        opt.port = port;
    if (res.args.client_port) |client_port|
        opt.client_port = client_port;
    if (res.args.min_buf_time) |min_buf_time|
        opt.min_buf_time = min_buf_time;
    if (res.args.max_buf_time) |max_buf_time|
        opt.max_buf_time = max_buf_time;

    try logz.setup(utils.allocator, .{
        .level = if (opt.debug) .Debug else .Info,
        .output = .stdout,
        .encoding = .logfmt,
    });
    defer logz.deinit();

    logz.info().ctx("Launching " ++ build_config.bin_name).stringSafe("version", build_config.version).log();

    var scheduler = try coro.Scheduler.init(utils.allocator, .{});
    defer scheduler.deinit();

    var ctx = try app.setup_proxy_context(opt);

    _ = try scheduler.spawn(app.launch_proxy, .{&ctx}, .{});

    try scheduler.run(.wait);

    const close_time = std.time.milliTimestamp();
    const uptime = try zul.DateTime.fromUnix(close_time - start_time, .milliseconds);
    logz.info().ctx("Closing " ++ build_config.bin_name).fmt("uptime", "{}", .{uptime.time()}).log();
}
