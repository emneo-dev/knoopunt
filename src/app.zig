const std = @import("std");

const aio = @import("aio");
const coro = @import("coro");
const logz = @import("logz");

const options = @import("options.zig");
const utils = @import("utils.zig");

const ConMappingStatus = enum {
    WaitingForServerSocket,
    WaitingForServerConnection,
    Running,
    ToBeClosed,
};

const tmp_buffer_size = 2048;

var rand_backend = std.Random.DefaultPrng.init(0);
var rand = std.Random.init(&rand_backend, @TypeOf(rand_backend).fill);

const ConMapping = struct {
    const Self = @This();

    client: std.posix.socket_t,
    server: std.posix.socket_t,
    c2s_data: std.ArrayListUnmanaged(u8),
    c2s_timeout: usize,
    c2s_w_size: usize,
    s2c_data: std.ArrayListUnmanaged(u8),
    s2c_timeout: usize,
    s2c_w_size: usize,
    status: ConMappingStatus,
    err: struct {
        connect: aio.Connect.Error = aio.Connect.Error.Canceled,
        socket: aio.Socket.Error = aio.Socket.Error.Canceled,
        read_srv: aio.Recv.Error = aio.Recv.Error.Canceled,
        read_cli: aio.Recv.Error = aio.Recv.Error.Canceled,
        write_srv: aio.Send.Error = aio.Send.Error.Canceled,
        write_cli: aio.Send.Error = aio.Send.Error.Canceled,
    },

    cd: []u8,
    cd_len: usize,
    sd: []u8,
    sd_len: usize,

    pub fn init(client: std.posix.socket_t) !Self {
        var self: Self = .{
            .client = client,
            .server = undefined,
            .c2s_data = .{},
            .c2s_timeout = 0,
            .c2s_w_size = 0,
            .s2c_data = .{},
            .s2c_timeout = 0,
            .s2c_w_size = 0,
            .status = .WaitingForServerSocket,
            .cd = undefined,
            .cd_len = 0,
            .sd = undefined,
            .sd_len = 0,
            .err = .{},
        };

        self.cd = try utils.allocator.alloc(u8, tmp_buffer_size);
        errdefer utils.allocator.free(self.cd);
        self.sd = try utils.allocator.alloc(u8, tmp_buffer_size);
        return self;
    }

    pub fn empty_temp_buffers(self: *Self) !void {
        inline for (.{ "cd", "sd" }) |f| {
            const len = @field(self, f ++ "_len");
            if (len == 0)
                continue;
            const data = @field(self, f)[0..len];
            if (comptime std.mem.eql(u8, f, "cd")) {
                try self.c2s_data.append(utils.allocator, data);
            } else {
                try self.s2c_data.append(utils.allocator, data);
            }
        }
    }

    pub fn can_send(self: *const Self) bool {
        return self.s2c_data.items.len != 0 or self.c2s_data.items.len != 0;
    }

    pub fn update_state(self: *Self, ns_passed: usize, opt: *const options) !void {
        //      Set the timeout and timeout_len if internal buffer not empty
        if (self.c2s_timeout == 0 and self.c2s_data.items.len != 0) {
            self.c2s_timeout = rand.intRangeAtMostBiased(usize, opt.min_buf_time * std.time.ns_per_ms, opt.max_buf_time * std.time.ns_per_ms);
        }
        if (self.s2c_timeout == 0 and self.s2c_data.items.len != 0) {
            self.s2c_timeout = rand.intRangeAtMostBiased(usize, opt.min_buf_time * std.time.ns_per_ms, opt.max_buf_time * std.time.ns_per_ms);
        }

        // Decrease all timeouts -> Depending also if the io_uring timeout triggered or not
        if (self.c2s_timeout != 0) self.c2s_timeout -= @min(self.c2s_timeout, ns_passed);
        if (self.s2c_timeout != 0) self.s2c_timeout -= @min(self.s2c_timeout, ns_passed);

        //      Remove sent data from buffers
        if (self.c2s_w_size != 0) {
            try self.c2s_data.replaceRange(utils.allocator, 0, self.c2s_w_size, &[_]u8{});
            self.c2s_w_size = 0;
        }
        if (self.s2c_w_size != 0) {
            try self.s2c_data.replaceRange(utils.allocator, 0, self.s2c_w_size, &[_]u8{});
            self.s2c_w_size = 0;
        }

        // Add received data to buffers
        if (self.cd_len != 0) {
            try self.c2s_data.appendSlice(utils.allocator, self.cd[0..self.cd_len]);
            self.cd_len = 0;
        }
        if (self.sd_len != 0) {
            try self.s2c_data.appendSlice(utils.allocator, self.sd[0..self.sd_len]);
            self.sd_len = 0;
        }

        // Change state
        if (self.status == .WaitingForServerSocket and self.err.socket == aio.Socket.Error.Success) {
            self.status = .WaitingForServerConnection;
        } else if (self.status == .WaitingForServerConnection and self.err.connect == aio.Connect.Error.Success) {
            self.status = .Running;
        }

        // Reset error values
        // TODO: Change this, I absolutely hate it >:(
        self.err.read_srv = aio.Recv.Error.Canceled;
        self.err.read_cli = aio.Recv.Error.Canceled;
    }
};

pub const Context = struct {
    opt: options,
    con_maps: std.ArrayList(ConMapping),
    srv_sock: std.posix.socket_t = undefined,
};

pub fn setup_proxy_context(opt: options) !Context {
    return .{
        .opt = opt,
        .con_maps = std.ArrayList(ConMapping).init(utils.allocator),
    };
}

// TODO: Make this atomic
var stopping: bool = false;

pub fn launch_proxy(ctx: *Context) !void {
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &ctx.srv_sock,
    });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, ctx.opt.client_port);
    try std.posix.setsockopt(ctx.srv_sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(ctx.srv_sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    }
    try std.posix.bind(ctx.srv_sock, &address.any, address.getOsSockLen());
    try std.posix.listen(ctx.srv_sock, 0);

    const srv_addr = try std.net.Address.parseIp4(ctx.opt.address, ctx.opt.port);
    while (true) {
        const max_operations = 64;
        var work = try aio.Dynamic.init(utils.allocator, max_operations);
        defer work.deinit(utils.allocator);

        var accepted_socket: std.posix.socket_t = -1;
        var accept_error: aio.Accept.Error = aio.Accept.Error.Canceled;
        try work.queue(.{
            aio.op(.accept, .{
                .socket = ctx.srv_sock,
                .out_socket = &accepted_socket,
                .out_error = &accept_error,
            }, .unlinked),
        }, {});
        logz.debug().ctx("Queuing accept").log();

        var smallest_timeout: usize = std.math.maxInt(usize);
        for (ctx.con_maps.items, 0..) |*i, idx| {
            switch (i.status) {
                // Queue server socket creation
                .WaitingForServerSocket => {
                    try work.queue(.{
                        aio.op(.socket, .{
                            .domain = std.posix.AF.INET,
                            .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                            .protocol = std.posix.IPPROTO.TCP,
                            .out_socket = &i.server,
                            .out_error = &i.err.socket,
                        }, .unlinked),
                    }, {});
                    logz.debug().ctx("Queuing socket").int("idx", idx).log();
                },
                // Queue server connections
                .WaitingForServerConnection => {
                    try work.queue(.{
                        aio.op(.connect, .{
                            .socket = i.server,
                            .addr = &srv_addr.any,
                            .addrlen = srv_addr.getOsSockLen(),
                            .out_error = &i.err.connect,
                        }, .unlinked),
                    }, {});
                    logz.debug().ctx("Queuing connect").int("idx", idx).log();
                },
                .Running => {
                    // Queue recv
                    try work.queue(.{
                        aio.op(.recv, .{
                            .socket = i.client,
                            .buffer = i.cd,
                            .out_read = &i.cd_len,
                            .out_error = &i.err.read_cli,
                        }, .unlinked),
                        aio.op(.recv, .{
                            .socket = i.server,
                            .buffer = i.sd,
                            .out_read = &i.sd_len,
                            .out_error = &i.err.read_srv,
                        }, .unlinked),
                    }, {});
                    logz.debug().ctx("Queuing recv").int("idx", idx).log();

                    if (i.can_send()) {
                        // Find smallest timeout
                        if (i.c2s_timeout != 0) smallest_timeout = @min(smallest_timeout, i.c2s_timeout);
                        if (i.s2c_timeout != 0) smallest_timeout = @min(smallest_timeout, i.s2c_timeout);

                        // Queue writes
                        if (i.c2s_timeout == 0 and i.c2s_data.items.len != 0) {
                            const size = rand.intRangeAtMostBiased(usize, 1, i.c2s_data.items.len);
                            try work.queue(.{
                                aio.op(.send, .{
                                    .socket = i.server,
                                    .buffer = i.c2s_data.items[0..size],
                                    .out_written = &i.c2s_w_size,
                                    .out_error = &i.err.write_srv,
                                }, .unlinked),
                            }, {});
                            logz.debug().ctx("Queuing c2s send").int("idx", idx).log();
                        }
                        if (i.s2c_timeout == 0 and i.s2c_data.items.len != 0) {
                            const size = rand.intRangeAtMostBiased(usize, 1, i.s2c_data.items.len);
                            try work.queue(.{
                                aio.op(.send, .{
                                    .socket = i.client,
                                    .buffer = i.s2c_data.items[0..size],
                                    .out_written = &i.s2c_w_size,
                                    .out_error = &i.err.write_cli,
                                }, .unlinked),
                            }, {});
                            logz.debug().ctx("Queuing s2c send").int("idx", idx).log();
                        }
                    }
                },
                .ToBeClosed => unreachable,
            }
        }

        var timeout_error: aio.Timeout.Error = undefined;

        // Queue timeout
        if (smallest_timeout != std.math.maxInt(usize)) {
            try work.queue(.{
                aio.op(.timeout, .{
                    .ns = smallest_timeout,
                    .out_error = &timeout_error,
                }, .unlinked),
            }, {});
            logz.debug().ctx("Queuing timeout").int("ns", smallest_timeout).log();
        }

        // Wait for loop to complete
        var timer = try std.time.Timer.start();
        logz.debug().ctx("Launching work loop").log();
        const res = try work.complete(.blocking, {});
        logz.debug().ctx("Finished work loop").fmt("res", "{}", .{res}).log();
        const ns_passed_timer = timer.read();

        // TODO: Add client to mappings
        if (accept_error == aio.Accept.Error.Success and accepted_socket >= 0) {
            logz.debug().ctx("Adding new client").fmt("fd", "{}", .{accepted_socket}).log();
            try ctx.con_maps.append(try ConMapping.init(accepted_socket));
        }

        // Get if the timeout triggered or not
        // TODO: Check if this is right -> It feels hella wrong
        const timeout_triggered = smallest_timeout != std.math.maxInt(usize) and timeout_error == aio.Timeout.Error.Success;
        const ns_passed = if (timeout_triggered) smallest_timeout else ns_passed_timer;

        for (ctx.con_maps.items) |*i|
            try i.update_state(ns_passed, &ctx.opt);

        // Disconnect and remove all clients in ToBeClosed state

        // If stopping and no clients have any internal data then close all connections and return
    }
}
