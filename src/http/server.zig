const std = @import("std");
const builtin = @import("builtin");
const tag = builtin.os.tag;
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/server");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

const _Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;
const ResponseSetOptions = Response.ResponseSetOptions;
const _SSE = @import("sse.zig").SSE;

const Provision = @import("provision.zig").Provision;
const Mime = @import("mime.zig").Mime;
const _Router = @import("router.zig").Router;
const _Route = @import("route.zig").Route;
const HTTPError = @import("lib.zig").HTTPError;

const AfterType = @import("../core/job.zig").AfterType;

const Pool = @import("tardy").Pool;
pub const Runtime = @import("tardy").Runtime;
pub const Task = @import("tardy").Task;
const TaskFn = @import("tardy").TaskFn;
pub const AsyncIOType = @import("tardy").AsyncIOType;
const TardyCreator = @import("tardy").Tardy;
const Cross = @import("tardy").Cross;

pub const RecvStatus = union(enum) {
    kill,
    recv,
    send: Pseudoslice,
    spawned,
};

/// Security Model to use.chinp acas
///
/// Default: .plain (plaintext)
pub const Security = union(enum) {
    plain,
    tls: struct {
        cert: TLSFileOptions,
        key: TLSFileOptions,
        cert_name: []const u8 = "CERTIFICATE",
        key_name: []const u8 = "PRIVATE KEY",
    },
};

/// Uses the current p.response to generate and queue up the sending
/// of a response. This is used when we already know what we want to send.
///
/// See: `route_and_respond`
pub inline fn raw_respond(p: *Provision) !RecvStatus {
    {
        const status_code: u16 = if (p.response.status) |status| @intFromEnum(status) else 0;
        const status_name = if (p.response.status) |status| @tagName(status) else "No Status";
        log.info("{d} - {d} {s}", .{ p.index, status_code, status_name });
    }

    const body = p.response.body orelse "";
    const header_buffer = try p.response.headers_into_buffer(p.buffer, @intCast(body.len));
    p.response.headers.clear();
    const pseudo = Pseudoslice.init(header_buffer, body, p.buffer);
    return .{ .send = pseudo };
}

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const ServerConfig = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Kernel Backlog Value.
    size_backlog: u31 = 512,
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER thread if using multi-threading.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You want to tune this to your expected number
    /// of maximum connections.
    ///
    /// Default: 1024
    size_connections_max: u16 = 1024,
    /// Maximum number of completions we can reap
    /// with a single call of reap().
    ///
    /// Default: 256
    size_completions_reap_max: u16 = 256,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1KB
    size_connection_arena_retain: u32 = 1024,
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1KB
    size_recv_buffer_retain: u32 = 1024,
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 4 KB.
    size_socket_buffer: u32 = 1024 * 4,
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MB.
    size_recv_buffer_max: u32 = 1024 * 1024 * 2,
    /// Maximum number of Headers in a Request/Response
    ///
    /// Default: 32
    num_header_max: u32 = 32,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    num_captures_max: u32 = 8,
    /// Maximum number of Queries in a URL
    ///
    /// Default: 8
    num_queries_max: u32 = 8,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MB.
    size_request_max: u32 = 1024 * 1024 * 2,
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KB.
    size_request_uri_max: u32 = 1024 * 2,
};

pub fn Server(comptime security: Security) type {
    const TLSContextType = comptime if (security == .tls) TLSContext else void;
    const TLSType = comptime if (security == .tls) ?TLS else void;

    return struct {
        const Self = @This();
        pub const Context = _Context(Self);
        pub const Router = _Router(Self);
        pub const Route = _Route(Self);
        pub const SSE = _SSE(Self);
        allocator: std.mem.Allocator,
        config: ServerConfig,
        addr: std.net.Address,
        tls_ctx: TLSContextType,
        router: *const Router,

        pub fn init(config: ServerConfig) Self {
            const tls_ctx = switch (comptime security) {
                .tls => |inner| TLSContext.init(.{
                    .allocator = config.allocator,
                    .cert = inner.cert,
                    .cert_name = inner.cert_name,
                    .key = inner.key,
                    .key_name = inner.key_name,
                    .size_tls_buffer_max = config.size_socket_buffer * 2,
                }) catch unreachable,
                .plain => void{},
            };

            return Self{
                .allocator = config.allocator,
                .config = config,
                .addr = undefined,
                .tls_ctx = tls_ctx,
                .router = undefined,
            };
        }

        pub fn deinit(self: *const Self) void {
            if (comptime security == .tls) {
                self.tls_ctx.deinit();
            }
        }

        pub fn bind(self: *Self, host: []const u8, port: u16) !void {
            assert(host.len > 0);
            assert(port > 0);

            self.addr = blk: {
                if (comptime tag.isDarwin() or tag.isBSD() or tag == .windows) {
                    break :blk try std.net.Address.parseIp(host, port);
                } else {
                    break :blk try std.net.Address.resolveIp(host, port);
                }
            };
        }

        pub fn close_task(rt: *Runtime, _: void, provision: *Provision) !void {
            assert(provision.job == .close);
            const server_socket = rt.storage.get("__zzz_server_socket", std.posix.socket_t);
            const pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

            log.info("{d} - closing connection", .{provision.index});

            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                const tls_ptr: *TLSType = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                tls_ptr.*.?.deinit();
                tls_ptr.* = null;
            }

            provision.socket = Cross.socket.INVALID_SOCKET;
            provision.job = .empty;
            _ = provision.arena.reset(.{ .retain_with_limit = config.size_connection_arena_retain });
            provision.response.clear();

            if (provision.recv_buffer.items.len > config.size_recv_buffer_retain) {
                provision.recv_buffer.shrinkRetainingCapacity(config.size_recv_buffer_retain);
            } else {
                provision.recv_buffer.clearRetainingCapacity();
            }

            pool.release(provision.index);

            const accept_queued = rt.storage.get_ptr("__zzz_accept_queued", bool);
            if (!accept_queued.*) {
                accept_queued.* = true;
                try rt.net.accept(
                    server_socket,
                    accept_task,
                    server_socket,
                );
            }
        }

        fn accept_task(rt: *Runtime, child_socket: std.posix.socket_t, socket: std.posix.socket_t) !void {
            const pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            const accept_queued = rt.storage.get_ptr("__zzz_accept_queued", bool);
            accept_queued.* = false;

            if (rt.scheduler.tasks.clean() >= 2) {
                accept_queued.* = true;
                try rt.net.accept(socket, accept_task, socket);
            }

            if (!Cross.socket.is_valid(child_socket)) {
                log.err("socket accept failed", .{});
                return error.AcceptFailed;
            }

            // This should never fail. It means that we have a dangling item.
            assert(pool.clean() > 0);
            const borrowed = pool.borrow() catch unreachable;

            log.info("{d} - accepting connection", .{borrowed.index});
            log.debug(
                "empty provision slots: {d}",
                .{pool.items.len - pool.dirty.count()},
            );
            assert(borrowed.item.job == .empty);

            try Cross.socket.disable_nagle(child_socket);
            try Cross.socket.to_nonblock(child_socket);

            const provision = borrowed.item;

            // Store the index of this item.
            provision.index = @intCast(borrowed.index);
            provision.socket = child_socket;
            log.debug("provision buffer size: {d}", .{provision.buffer.len});

            switch (comptime security) {
                .tls => |_| {
                    const tls_ctx = rt.storage.get_const_ptr("__zzz_tls_ctx", TLSContextType);
                    const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                    assert(tls_ptr.* == null);

                    tls_ptr.* = tls_ctx.create(child_socket) catch |e| {
                        log.err("{d} - tls creation failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSCreationFailed;
                    };

                    const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
                        log.err("{d} - tls start handshake failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSStartHandshakeFailed;
                    };

                    provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
                    try rt.net.recv(borrowed.item, handshake_task, child_socket, recv_buf);
                },
                .plain => {
                    provision.job = .{ .recv = .{ .count = 0 } };
                    try rt.net.recv(provision, recv_task, child_socket, provision.buffer);
                },
            }
        }

        fn recv_task(rt: *Runtime, length: i32, provision: *Provision) !void {
            assert(provision.job == .recv);
            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);
            const router = rt.storage.get_const_ptr("__zzz_router", Router);

            const recv_job = &provision.job.recv;

            // If the socket is closed.
            if (length <= 0) {
                provision.job = .close;
                try rt.net.close(provision, close_task, provision.socket);
                return;
            }

            log.debug("{d} - recv triggered", .{provision.index});

            const recv_count: usize = @intCast(length);
            recv_job.count += recv_count;
            const pre_recv_buffer = provision.buffer[0..recv_count];

            const recv_buffer = blk: {
                switch (comptime security) {
                    .tls => |_| {
                        const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                        const tls_ptr: *TLSType = &tls_slice[provision.index];
                        assert(tls_ptr.* != null);

                        break :blk tls_ptr.*.?.decrypt(pre_recv_buffer) catch |e| {
                            log.err("{d} - decrypt failed: {any}", .{ provision.index, e });
                            provision.job = .close;
                            try rt.net.close(provision, close_task, provision.socket);
                            return error.TLSDecryptFailed;
                        };
                    },
                    .plain => break :blk pre_recv_buffer,
                }
            };

            const status = try on_recv(recv_buffer, rt, provision, router, config);

            switch (status) {
                .spawned => return,
                .kill => {
                    rt.stop();
                    return error.Killed;
                },
                .recv => {
                    try rt.net.recv(
                        provision,
                        recv_task,
                        provision.socket,
                        provision.buffer,
                    );
                },
                .send => |pslice| {
                    const first_buffer = try prepare_send(rt, provision, .recv, pslice);
                    try rt.net.send(
                        provision,
                        send_then_recv_task,
                        provision.socket,
                        first_buffer,
                    );
                },
            }
        }

        fn handshake_task(rt: *Runtime, length: i32, provision: *Provision) !void {
            assert(security == .tls);
            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                assert(provision.job == .handshake);
                const handshake_job = &provision.job.handshake;

                const tls_ptr: *TLSType = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                log.debug("processing handshake", .{});
                handshake_job.count += 1;

                if (length <= 0) {
                    log.debug("handshake connection closed", .{});
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return error.TLSHandshakeClosed;
                }

                if (handshake_job.count >= 50) {
                    log.debug("handshake taken too many cycles", .{});
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return error.TLSHandshakeTooManyCycles;
                }

                const hs_length: usize = @intCast(length);

                const hstate = switch (handshake_job.state) {
                    .recv => tls_ptr.*.?.continue_handshake(.{ .recv = @intCast(hs_length) }),
                    .send => tls_ptr.*.?.continue_handshake(.{ .send = @intCast(hs_length) }),
                } catch |e| {
                    log.err("{d} - tls handshake failed={any}", .{ provision.index, e });
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return error.TLSHandshakeRecvFailed;
                };

                switch (hstate) {
                    .recv => |buf| {
                        log.debug("queueing recv in handshake", .{});
                        handshake_job.state = .recv;
                        try rt.net.recv(provision, handshake_task, provision.socket, buf);
                    },
                    .send => |buf| {
                        log.debug("queueing send in handshake", .{});
                        handshake_job.state = .send;
                        try rt.net.send(provision, handshake_task, provision.socket, buf);
                    },
                    .complete => {
                        log.debug("handshake complete", .{});
                        provision.job = .{ .recv = .{ .count = 0 } };
                        try rt.net.recv(provision, recv_task, provision.socket, provision.buffer);
                    },
                }
            }
        }

        /// Prepares the provision send_job and returns the first send chunk
        pub fn prepare_send(rt: *Runtime, provision: *Provision, after: AfterType, pslice: Pseudoslice) ![]const u8 {
            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);
            const plain_buffer = pslice.get(0, config.size_socket_buffer);

            switch (comptime security) {
                .tls => {
                    const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                    assert(tls_ptr.* != null);

                    const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch |e| {
                        log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSEncryptFailed;
                    };

                    provision.job = .{
                        .send = .{
                            .after = after,
                            .slice = pslice,
                            .count = @intCast(plain_buffer.len),
                            .security = .{
                                .tls = .{
                                    .encrypted = encrypted_buffer,
                                    .encrypted_count = 0,
                                },
                            },
                        },
                    };

                    return encrypted_buffer;
                },
                .plain => {
                    provision.job = .{
                        .send = .{
                            .after = after,
                            .slice = pslice,
                            .count = 0,
                            .security = .plain,
                        },
                    };

                    return plain_buffer;
                },
            }
        }

        pub const send_then_sse_task = send_then(struct {
            fn inner(rt: *Runtime, success: bool, provision: *Provision) !void {
                const send_job = provision.job.send;
                assert(send_job.after == .sse);
                const func: TaskFn(bool, *anyopaque) = @ptrCast(@alignCast(send_job.after.sse.func));
                const ctx: *anyopaque = @ptrCast(@alignCast(send_job.after.sse.ctx));
                try @call(.auto, func, .{ rt, success, ctx });

                if (!success) {
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                }
            }
        }.inner);

        pub const send_then_recv_task = send_then(struct {
            fn inner(rt: *Runtime, success: bool, provision: *Provision) !void {
                if (!success) {
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return;
                }

                const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

                log.debug("{d} - queueing a new recv", .{provision.index});
                _ = provision.arena.reset(.{
                    .retain_with_limit = config.size_connection_arena_retain,
                });
                provision.recv_buffer.clearRetainingCapacity();
                provision.job = .{ .recv = .{ .count = 0 } };

                try rt.net.recv(
                    provision,
                    recv_task,
                    provision.socket,
                    provision.buffer,
                );
            }
        }.inner);

        fn send_then(comptime func: TaskFn(bool, *Provision)) TaskFn(i32, *Provision) {
            return struct {
                fn send_then_inner(rt: *Runtime, length: i32, provision: *Provision) !void {
                    assert(provision.job == .send);
                    const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

                    // If the socket is closed.
                    if (length <= 0) {
                        try @call(.always_inline, func, .{ rt, false, provision });
                        return;
                    }

                    const send_job = &provision.job.send;

                    log.debug("{d} - send triggered", .{provision.index});
                    const send_count: usize = @intCast(length);
                    log.debug("{d} - sent length: {d}", .{ provision.index, send_count });

                    switch (comptime security) {
                        .tls => {
                            assert(send_job.security == .tls);

                            const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                            const job_tls = &send_job.security.tls;
                            job_tls.encrypted_count += send_count;

                            if (job_tls.encrypted_count >= job_tls.encrypted.len) {
                                if (send_job.count >= send_job.slice.len) {
                                    try @call(.always_inline, func, .{ rt, true, provision });
                                } else {
                                    // Queue a new chunk up for sending.
                                    log.debug(
                                        "{d} - sending next chunk starting at index {d}",
                                        .{ provision.index, send_job.count },
                                    );

                                    const inner_slice = send_job.slice.get(
                                        send_job.count,
                                        send_job.count + config.size_socket_buffer,
                                    );

                                    send_job.count += @intCast(inner_slice.len);

                                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                                    assert(tls_ptr.* != null);

                                    const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch |e| {
                                        log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                                        provision.job = .close;
                                        try rt.net.close(provision, close_task, provision.socket);
                                        return error.TLSEncryptFailed;
                                    };

                                    job_tls.encrypted = encrypted;
                                    job_tls.encrypted_count = 0;

                                    try rt.net.send(
                                        provision,
                                        send_then_recv_task,
                                        provision.socket,
                                        job_tls.encrypted,
                                    );
                                }
                            } else {
                                log.debug(
                                    "{d} - sending next encrypted chunk starting at index {d}",
                                    .{ provision.index, job_tls.encrypted_count },
                                );

                                const remainder = job_tls.encrypted[job_tls.encrypted_count..];
                                try rt.net.send(
                                    provision,
                                    send_then_recv_task,
                                    provision.socket,
                                    remainder,
                                );
                            }
                        },
                        .plain => {
                            assert(send_job.security == .plain);
                            send_job.count += send_count;

                            if (send_job.count >= send_job.slice.len) {
                                try @call(.always_inline, func, .{ rt, true, provision });
                            } else {
                                log.debug(
                                    "{d} - sending next chunk starting at index {d}",
                                    .{ provision.index, send_job.count },
                                );

                                const plain_buffer = send_job.slice.get(
                                    send_job.count,
                                    send_job.count + config.size_socket_buffer,
                                );

                                log.debug("socket buffer size: {d}", .{config.size_socket_buffer});

                                log.debug("{d} - chunk ends at: {d}", .{
                                    provision.index,
                                    plain_buffer.len + send_job.count,
                                });

                                try rt.net.send(
                                    provision,
                                    send_then_recv_task,
                                    provision.socket,
                                    plain_buffer,
                                );
                            }
                        },
                    }
                }
            }.send_then_inner;
        }

        pub inline fn serve(self: *Self, router: *const Router, rt: *Runtime) !void {
            self.router = router;

            log.info("server listening...", .{});
            log.info("security mode: {s}", .{@tagName(security)});

            const socket = try self.create_socket();
            try std.posix.bind(socket, &self.addr.any, self.addr.getOsSockLen());
            try std.posix.listen(socket, self.config.size_backlog);

            const provision_pool = try rt.allocator.create(Pool(Provision));
            provision_pool.* = try Pool(Provision).init(
                rt.allocator,
                self.config.size_connections_max,
                self.config,
                Provision.init_hook,
            );

            try rt.storage.store_ptr("__zzz_router", @constCast(router));
            try rt.storage.store_ptr("__zzz_provision_pool", provision_pool);
            try rt.storage.store_alloc("__zzz_config", self.config);

            if (comptime security == .tls) {
                const tls_slice = try rt.allocator.alloc(
                    TLSType,
                    self.config.size_connections_max,
                );
                if (comptime security == .tls) {
                    for (tls_slice) |*tls| {
                        tls.* = null;
                    }
                }

                // since slices are fat pointers...
                try rt.storage.store_alloc("__zzz_tls_slice", tls_slice);
                try rt.storage.store_alloc("__zzz_tls_ctx", self.tls_ctx);
            }

            try rt.storage.store_alloc("__zzz_server_socket", socket);
            try rt.storage.store_alloc("__zzz_accept_queued", true);

            try rt.net.accept(socket, accept_task, socket);
        }

        pub inline fn clean(rt: *Runtime) !void {
            // clean up socket.
            const server_socket = rt.storage.get("__zzz_server_socket", std.posix.socket_t);
            std.posix.close(server_socket);

            // clean up provision pool.
            const provision_pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            provision_pool.deinit(rt.allocator, Provision.deinit_hook);
            rt.allocator.destroy(provision_pool);

            // clean up TLS.
            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                rt.allocator.free(tls_slice);
            }
        }

        fn create_socket(self: *const Self) !std.posix.socket_t {
            const socket: std.posix.socket_t = blk: {
                const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
                break :blk try std.posix.socket(
                    self.addr.any.family,
                    socket_flags,
                    std.posix.IPPROTO.TCP,
                );
            };

            log.debug("socket | t: {s} v: {any}", .{ @typeName(std.posix.socket_t), socket });

            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT_LB,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEADDR,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }

            return socket;
        }

        fn route_and_respond(runtime: *Runtime, p: *Provision, router: *const Router) !RecvStatus {
            route: {
                const found = router.get_route_from_host(p.request.uri, p.captures, &p.queries);
                if (found) |f| {
                    const handler = f.route.get_handler(p.request.method);

                    if (handler) |h_with_data| {
                        const context: *Context = try p.arena.allocator().create(Context);
                        context.* = .{
                            .allocator = p.arena.allocator(),
                            .runtime = runtime,
                            .request = &p.request,
                            .response = &p.response,
                            .path = p.request.uri,
                            .captures = f.captures,
                            .queries = f.queries,
                            .provision = p,
                        };

                        @call(.auto, h_with_data.handler, .{
                            context,
                            @as(*anyopaque, @ptrFromInt(h_with_data.data)),
                        }) catch |e| {
                            log.err("\"{s}\" handler failed with error: {}", .{ p.request.uri, e });
                            p.response.set(.{
                                .status = .@"Internal Server Error",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            return try raw_respond(p);
                        };

                        return .spawned;
                    } else {
                        // If we match the route but not the method.
                        p.response.set(.{
                            .status = .@"Method Not Allowed",
                            .mime = Mime.HTML,
                            .body = "405 Method Not Allowed",
                        });

                        // We also need to add to Allow header.
                        // This uses the connection's arena to allocate 64 bytes.
                        const allowed = f.route.get_allowed(p.arena.allocator()) catch {
                            p.response.set(.{
                                .status = .@"Internal Server Error",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            break :route;
                        };

                        p.response.headers.add("Allow", allowed) catch {
                            p.response.set(.{
                                .status = .@"Internal Server Error",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            break :route;
                        };

                        break :route;
                    }
                }

                // Didn't match any route.
                p.response.set(.{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                    .body = "404 Not Found",
                });
                break :route;
            }

            if (p.response.status == .Kill) {
                return .kill;
            }

            return try raw_respond(p);
        }

        inline fn on_recv(
            buffer: []const u8,
            rt: *Runtime,
            provision: *Provision,
            router: *const Router,
            config: *const ServerConfig,
        ) !RecvStatus {
            var stage = provision.stage;
            const job = provision.job.recv;

            if (job.count >= config.size_request_max) {
                provision.response.set(.{
                    .status = .@"Content Too Large",
                    .mime = Mime.HTML,
                    .body = "Request was too large",
                });

                return try raw_respond(provision);
            }

            switch (stage) {
                .header => {
                    const start = provision.recv_buffer.items.len -| 4;
                    try provision.recv_buffer.appendSlice(buffer);
                    const header_ends = std.mem.lastIndexOf(u8, provision.recv_buffer.items[start..], "\r\n\r\n");

                    // Basically, this means we haven't finished processing the header.
                    if (header_ends == null) {
                        log.debug("{d} - header doesn't end in this chunk, continue", .{provision.index});
                        return .recv;
                    }

                    log.debug("{d} - parsing header", .{provision.index});
                    // The +4 is to account for the slice we match.
                    const header_end: u32 = @intCast(header_ends.? + 4);
                    provision.request.parse_headers(provision.recv_buffer.items[0..header_end], .{
                        .size_request_max = config.size_request_max,
                        .size_request_uri_max = config.size_request_uri_max,
                    }) catch |e| {
                        switch (e) {
                            HTTPError.ContentTooLarge => {
                                provision.response.set(.{
                                    .status = .@"Content Too Large",
                                    .mime = Mime.HTML,
                                    .body = "Request was too large",
                                });
                            },
                            HTTPError.TooManyHeaders => {
                                provision.response.set(.{
                                    .status = .@"Request Header Fields Too Large",
                                    .mime = Mime.HTML,
                                    .body = "Too Many Headers",
                                });
                            },
                            HTTPError.MalformedRequest => {
                                provision.response.set(.{
                                    .status = .@"Bad Request",
                                    .mime = Mime.HTML,
                                    .body = "Malformed Request",
                                });
                            },
                            HTTPError.URITooLong => {
                                provision.response.set(.{
                                    .status = .@"URI Too Long",
                                    .mime = Mime.HTML,
                                    .body = "URI Too Long",
                                });
                            },
                            HTTPError.InvalidMethod => {
                                provision.response.set(.{
                                    .status = .@"Not Implemented",
                                    .mime = Mime.HTML,
                                    .body = "Not Implemented",
                                });
                            },
                            HTTPError.HTTPVersionNotSupported => {
                                provision.response.set(.{
                                    .status = .@"HTTP Version Not Supported",
                                    .mime = Mime.HTML,
                                    .body = "HTTP Version Not Supported",
                                });
                            },
                        }

                        return raw_respond(provision) catch unreachable;
                    };

                    // Logging information about Request.
                    log.info("{d} - \"{s} {s}\" {s}", .{
                        provision.index,
                        @tagName(provision.request.method),
                        provision.request.uri,
                        provision.request.headers.get("User-Agent") orelse "N/A",
                    });

                    // HTTP/1.1 REQUIRES a Host header to be present.
                    const is_http_1_1 = provision.request.version == .@"HTTP/1.1";
                    const is_host_present = provision.request.headers.get("Host") != null;
                    if (is_http_1_1 and !is_host_present) {
                        provision.response.set(.{
                            .status = .@"Bad Request",
                            .mime = Mime.HTML,
                            .body = "Missing \"Host\" Header",
                        });

                        return try raw_respond(provision);
                    }

                    if (!provision.request.expect_body()) {
                        return try route_and_respond(rt, provision, router);
                    }

                    // Everything after here is a Request that is expecting a body.
                    const content_length = blk: {
                        const length_string = provision.request.headers.get("Content-Length") orelse {
                            break :blk 0;
                        };

                        break :blk try std.fmt.parseInt(u32, length_string, 10);
                    };

                    if (header_end < provision.recv_buffer.items.len) {
                        const difference = provision.recv_buffer.items.len - header_end;
                        if (difference == content_length) {
                            // Whole Body
                            log.debug("{d} - got whole body with header", .{provision.index});
                            const body_end = header_end + difference;
                            provision.request.set(.{
                                .body = provision.recv_buffer.items[header_end..body_end],
                            });
                            return try route_and_respond(rt, provision, router);
                        } else {
                            // Partial Body
                            log.debug("{d} - got partial body with header", .{provision.index});
                            stage = .{ .body = header_end };
                            return .recv;
                        }
                    } else if (header_end == provision.recv_buffer.items.len) {
                        // Body of length 0 probably or only got header.
                        if (content_length == 0) {
                            log.debug("{d} - got body of length 0", .{provision.index});
                            // Body of Length 0.
                            provision.request.set(.{ .body = "" });
                            return try route_and_respond(rt, provision, router);
                        } else {
                            // Got only header.
                            log.debug("{d} - got all header aka no body", .{provision.index});
                            stage = .{ .body = header_end };
                            return .recv;
                        }
                    } else unreachable;
                },

                .body => |header_end| {
                    // We should ONLY be here if we expect there to be a body.
                    assert(provision.request.expect_body());
                    log.debug("{d} - body matching", .{provision.index});

                    const content_length = blk: {
                        const length_string = provision.request.headers.get("Content-Length") orelse {
                            provision.response.set(.{
                                .status = .@"Length Required",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            return try raw_respond(provision);
                        };

                        break :blk try std.fmt.parseInt(u32, length_string, 10);
                    };

                    const request_length = header_end + content_length;

                    // If this body will be too long, abort early.
                    if (request_length > config.size_request_max) {
                        provision.response.set(.{
                            .status = .@"Content Too Large",
                            .mime = Mime.HTML,
                            .body = "",
                        });
                        return try raw_respond(provision);
                    }

                    if (job.count >= request_length) {
                        provision.request.set(.{
                            .body = provision.recv_buffer.items[header_end..request_length],
                        });
                        return try route_and_respond(rt, provision, router);
                    } else {
                        return .recv;
                    }
                },
            }
        }
    };
}
