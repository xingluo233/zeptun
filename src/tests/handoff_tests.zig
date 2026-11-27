const std = @import("std");
const zeptun = @import("zeptun");
const c = @import("c_abi");
const addr = zeptun.addr;
const config = zeptun.config;
const engine = zeptun.engine;
const external = zeptun.device.external;
const intercept = zeptun.intercept;
const parse = zeptun.packet.parse;
const gso = zeptun.packet.gso;
const sys = zeptun.io.sys;
const verdict = zeptun.flow.verdict;
const queue = zeptun.queue;

fn cAbiUdpCallback(_: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]const c.ZeptunUdpMeta) callconv(.c) void {}
fn cAbiTcpCallback(_: ?*anyopaque, _: [*c]const c.ZeptunTcpMeta, _: usize) callconv(.c) void {}

test "public C handoff ABI layout" {
    try std.testing.expectEqual(@as(usize, 304), @sizeOf(c.ZeptunUdpMeta));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(c.ZeptunUdpMeta, "name"));
    try std.testing.expectEqual(@as(usize, 294), @sizeOf(c.ZeptunTcpMeta));
    try std.testing.expectEqual(@as(usize, 38), @offsetOf(c.ZeptunTcpMeta, "name"));
    const tcp_cb: c.zeptun_tcp_cb = cAbiTcpCallback;
    const udp_cb: c.zeptun_udp_cb = cAbiUdpCallback;
    _ = tcp_cb;
    _ = udp_cb;
}

const Collector = struct {
    mutex: queue.SpinLock = .{},
    packets: [256][4096]u8 = undefined,
    lens: [256]usize = undefined,
    count: usize = 0,
    read_index: usize = 0,

    fn output(ctx: ?*anyopaque, packets: [*]const external.Packet, n: usize) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        for (packets[0..n]) |p| {
            if (self.count == self.packets.len) return;
            const len = @min(p.len, self.packets[0].len);
            @memcpy(self.packets[self.count][0..len], p.data[0..len]);
            self.lens[self.count] = len;
            self.count += 1;
        }
    }

    fn next(self: *Collector, timeout_ms: u64, out: []u8) ?[]u8 {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (sys.monotonicMs() < deadline) {
            self.mutex.lock();
            if (self.read_index < self.count) {
                const i = self.read_index;
                self.read_index += 1;
                const len = self.lens[i];
                @memcpy(out[0..len], self.packets[i][0..len]);
                self.mutex.unlock();
                return out[0..len];
            }
            self.mutex.unlock();
            sys.sleepMs(1);
        }
        return null;
    }
};

fn buildUdp4(buf: []u8, src: addr.Endpoint, dst: addr.Endpoint, payload: []const u8) []u8 {
    const total = 28 + payload.len;
    zeptun.stack.ip.writeIpv4(buf, src.addr.slice(), dst.addr.slice(), parse.proto.udp, @intCast(8 + payload.len), 64, 0, 1);
    parse.setBe16(buf, 20, src.port);
    parse.setBe16(buf, 22, dst.port);
    parse.setBe16(buf, 24, @intCast(8 + payload.len));
    buf[26] = 0;
    buf[27] = 0;
    @memcpy(buf[28..][0..payload.len], payload);
    const p = tryParseIp(buf[0..total]);
    gso.setFullChecksum(buf[0..total], p, parse.proto.udp, 26);
    return buf[0..total];
}

fn tryParseIp(data: []const u8) parse.Ip {
    return parse.parseIp(data) catch unreachable;
}

const TcpSeg = struct {
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16 = 65535,
    options: []const u8 = &.{},
    payload: []const u8 = &.{},
};

fn buildTcp4(buf: []u8, src: addr.Endpoint, dst: addr.Endpoint, s: TcpSeg) []u8 {
    const opt_len = (s.options.len + 3) / 4 * 4;
    const tcp_len = 20 + opt_len + s.payload.len;
    const total = 20 + tcp_len;
    zeptun.stack.ip.writeIpv4(buf, src.addr.slice(), dst.addr.slice(), parse.proto.tcp, @intCast(tcp_len), 64, 0, 7);
    const tcp = buf[20..];
    parse.setBe16(tcp, 0, src.port);
    parse.setBe16(tcp, 2, dst.port);
    parse.setBe32(tcp, 4, s.seq);
    parse.setBe32(tcp, 8, s.ack);
    tcp[12] = @intCast((20 + opt_len) << 2);
    tcp[13] = s.flags;
    parse.setBe16(tcp, 14, s.window);
    @memset(tcp[16..20], 0);
    @memset(tcp[20..][0..opt_len], 1);
    @memcpy(tcp[20..][0..s.options.len], s.options);
    @memcpy(tcp[20 + opt_len ..][0..s.payload.len], s.payload);
    const p = parse.parseIp(buf[0..total]) catch unreachable;
    gso.setFullChecksum(buf[0..total], p, parse.proto.tcp, 36);
    return buf[0..total];
}

/// The handoff tests use the external device so they exercise the same
/// dispatch/stack/handler path as a TUN device without requiring privileges.
fn externalConfig() config.Config {
    var cfg = config.Config.fromPreset(.mobile);
    cfg.device.kind = .external;
    cfg.stack.mode = .userspace;
    cfg.handler.kind = .direct;
    cfg.io.workers = 1;
    cfg.stack.tcp_early_accept = .off;
    cfg.log_level = .warn;
    return cfg;
}

fn waitUntil(comptime T: type, value: *const std.atomic.Value(T), want: T, timeout_ms: u64) bool {
    const deadline = sys.monotonicMs() + timeout_ms;
    while (sys.monotonicMs() < deadline) {
        if (value.load(.acquire) == want) return true;
        sys.sleepMs(1);
    }
    return value.load(.acquire) == want;
}

const UdpCapture = struct {
    e: *engine.Engine,
    calls: std.atomic.Value(u32) = .init(0),
    filter_calls: std.atomic.Value(u32) = .init(0),
    last_port: std.atomic.Value(u16) = .init(0),
    last_len: std.atomic.Value(usize) = .init(0),
    last_payload_len: std.atomic.Value(u32) = .init(0),
    reply: bool = false,

    fn callback(ctx: ?*anyopaque, packet: [*]const u8, len: usize, meta: *const intercept.Meta) callconv(.c) void {
        const self: *UdpCapture = @ptrCast(@alignCast(ctx.?));
        _ = packet;
        self.last_port.store(meta.dst_port, .release);
        self.last_len.store(len, .release);
        self.last_payload_len.store(meta.payload_len, .release);
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (self.reply) {
            var out: [2048]u8 = undefined;
            const src = addr.Endpoint{ .addr = addr.Address.fromSlice(meta.dst[0..4]), .port = meta.dst_port };
            const dst = addr.Endpoint{ .addr = addr.Address.fromSlice(meta.src[0..4]), .port = meta.src_port };
            const raw = buildUdp4(&out, src, dst, "reply");
            const n = self.e.sendPackets(&.{.{ .data = raw.ptr, .len = raw.len }});
            std.debug.assert(n == 1);
        }
    }

    fn filter(ctx: ?*anyopaque, packet: [*]const u8, len: usize, meta: *const intercept.Meta) callconv(.c) c_int {
        const self: *UdpCapture = @ptrCast(@alignCast(ctx.?));
        _ = packet;
        _ = len;
        _ = self.filter_calls.fetchAdd(1, .acq_rel);
        return if (meta.dst_port == 8443) 1 else 0;
    }
};

fn injectUdp(e: *engine.Engine, src_port: u16, dst_port: u16, payload: []const u8) !void {
    const src = try addr.Endpoint.parse("10.0.0.2:0");
    const dst = try addr.Endpoint.parse("1.2.3.4:0");
    const s = addr.Endpoint{ .addr = src.addr, .port = src_port };
    const d = addr.Endpoint{ .addr = dst.addr, .port = dst_port };
    var raw: [2048]u8 = undefined;
    const pkt = buildUdp4(&raw, s, d, payload);
    try std.testing.expectEqual(@as(usize, 1), e.external.?.injectBatch(&.{.{ .data = pkt.ptr, .len = pkt.len }}));
}

test "UDP callback filter metadata and reply" {
    var collector: Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(Collector.output, &collector);
    var cap = UdpCapture{ .e = e, .reply = true };
    try e.setUdpInterceptPorts(&.{443});
    try e.setUdpFilter(UdpCapture.filter, &cap);
    try e.setUdpCallback(UdpCapture.callback, &cap);
    try e.start();

    try injectUdp(e, 53000, 443, "quic");
    try std.testing.expect(waitUntil(u32, &cap.calls, 1, 3000));
    try std.testing.expectEqual(@as(u16, 443), cap.last_port.load(.acquire));
    try std.testing.expectEqual(@as(u32, 4), cap.last_payload_len.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), cap.filter_calls.load(.acquire));

    var out: [2048]u8 = undefined;
    const reply = collector.next(3000, &out) orelse return error.NoReply;
    const p = try parse.parse(reply);
    try std.testing.expect(p.l4 == .udp);
    try std.testing.expectEqual(@as(u16, 53000), p.l4.udp.dst_port);
    try std.testing.expectEqualStrings("reply", reply[p.payload_off..][0..p.payload_len]);
    e.stop();
}

test "UDP filter selects an unlisted port and leaves another port normal" {
    var collector: Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(Collector.output, &collector);
    var cap = UdpCapture{ .e = e };
    try e.setUdpInterceptPorts(&.{443});
    try e.setUdpFilter(UdpCapture.filter, &cap);
    try e.setUdpCallback(UdpCapture.callback, &cap);
    try e.start();

    try injectUdp(e, 53001, 8443, "filter");
    try std.testing.expect(waitUntil(u32, &cap.calls, 1, 3000));
    try std.testing.expectEqual(@as(u32, 1), cap.filter_calls.load(.acquire));

    try injectUdp(e, 53002, 9999, "normal");
    const deadline = sys.monotonicMs() + 500;
    while (sys.monotonicMs() < deadline) sys.sleepMs(1);
    try std.testing.expectEqual(@as(u32, 1), cap.calls.load(.acquire));
    e.stop();
}

const JudgeCtx = struct {
    calls: std.atomic.Value(u32) = .init(0),
    action: u32,
    fn callback(ctx: ?*anyopaque, flow: *const verdict.Flow) callconv(.c) u32 {
        const self: *JudgeCtx = @ptrCast(@alignCast(ctx.?));
        _ = flow;
        _ = self.calls.fetchAdd(1, .acq_rel);
        return self.action;
    }
};

test "direct verdict bypasses both UDP and TCP handoff" {
    var collector: Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(Collector.output, &collector);
    var udp_cap = UdpCapture{ .e = e };
    var tcp_cap: TcpCapture = .{};
    var judge = JudgeCtx{ .action = 1 }; // direct
    try e.setUdpInterceptPorts(&.{443});
    try e.setTcpInterceptPorts(&.{443});
    try e.setUdpCallback(UdpCapture.callback, &udp_cap);
    try e.setTcpCallback(TcpCapture.callback, &tcp_cap);
    e.setJudge(JudgeCtx.callback, &judge);
    try e.start();

    try injectUdp(e, 53004, 443, "direct");
    var client = TcpClient{ .e = e, .collector = &collector, .client = try addr.Endpoint.parse("10.0.0.2:50004"), .server = try addr.Endpoint.parse("1.2.3.4:443") };
    try client.send(.{ .seq = 100, .ack = 0, .flags = 0x02 });
    const deadline = sys.monotonicMs() + 300;
    while (sys.monotonicMs() < deadline) sys.sleepMs(1);
    try std.testing.expectEqual(@as(u32, 0), udp_cap.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tcp_cap.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), judge.calls.load(.acquire));
    e.stop();
}

test "flow verdict takes priority over UDP and TCP handoff" {
    var collector: Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(Collector.output, &collector);
    var udp_cap = UdpCapture{ .e = e };
    var tcp_cap: TcpCapture = .{};
    var judge = JudgeCtx{ .action = 2 }; // drop
    try e.setUdpInterceptPorts(&.{443});
    try e.setTcpInterceptPorts(&.{443});
    try e.setUdpCallback(UdpCapture.callback, &udp_cap);
    try e.setTcpCallback(TcpCapture.callback, &tcp_cap);
    e.setJudge(JudgeCtx.callback, &judge);
    try e.start();

    try injectUdp(e, 53003, 443, "drop");
    var tcp = TcpClient{ .e = e, .collector = &collector, .client = try addr.Endpoint.parse("10.0.0.2:50003"), .server = try addr.Endpoint.parse("1.2.3.4:443") };
    try tcp.send(.{ .seq = 100, .ack = 0, .flags = 0x02 });
    const deadline = sys.monotonicMs() + 300;
    while (sys.monotonicMs() < deadline) sys.sleepMs(1);
    try std.testing.expectEqual(@as(u32, 0), udp_cap.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), tcp_cap.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), judge.calls.load(.acquire));
    e.stop();
}

const TcpCapture = struct {
    calls: std.atomic.Value(u32) = .init(0),
    sock: std.atomic.Value(usize) = .init(0),
    meta_port: std.atomic.Value(u16) = .init(0),

    fn callback(ctx: ?*anyopaque, meta: *const intercept.TcpMeta, sock: usize) callconv(.c) void {
        const self: *TcpCapture = @ptrCast(@alignCast(ctx.?));
        self.meta_port.store(meta.dst_port, .release);
        self.sock.store(sock, .release);
        _ = self.calls.fetchAdd(1, .acq_rel);
    }
};

test "TCP handoff rejects system and hybrid stacks at registration" {
    for ([_]config.StackMode{ .system, .hybrid }) |mode| {
        var cfg = config.Config.fromPreset(.desktop);
        cfg.stack.mode = mode;
        cfg.handler.kind = .direct;
        const e = engine.Engine.create(std.testing.allocator, cfg) catch |err| {
            if (err == error.NotSupported) continue;
            return err;
        };
        defer e.destroy();
        var cap: TcpCapture = .{};
        try std.testing.expectError(error.NotSupported, e.setTcpCallback(TcpCapture.callback, &cap));
    }
}

const TcpClient = struct {
    e: *engine.Engine,
    collector: *Collector,
    client: addr.Endpoint,
    server: addr.Endpoint,
    snd_nxt: u32 = 1000,
    rcv_nxt: u32 = 0,

    fn send(self: *TcpClient, seg: TcpSeg) !void {
        var raw: [2048]u8 = undefined;
        const pkt = buildTcp4(&raw, self.client, self.server, seg);
        try std.testing.expectEqual(@as(usize, 1), self.e.external.?.injectBatch(&.{.{ .data = pkt.ptr, .len = pkt.len }}));
    }

    fn nextInto(self: *TcpClient, raw: []u8, timeout_ms: u64) !parse.Packet {
        const bytes = self.collector.next(timeout_ms, raw) orelse return error.NoPacket;
        const p = try parse.parse(bytes);
        if (p.l4 != .tcp) return error.UnexpectedProtocol;
        return p;
    }
};

test "TCP callback waits for ACK and socket carries both directions and close" {
    var collector: Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(Collector.output, &collector);
    var cap: TcpCapture = .{};
    try e.setTcpInterceptPorts(&.{443});
    try e.setTcpCallback(TcpCapture.callback, &cap);
    try e.start();

    var client = TcpClient{ .e = e, .collector = &collector, .client = try addr.Endpoint.parse("10.0.0.2:50000"), .server = try addr.Endpoint.parse("1.2.3.4:443") };
    var raw: [2048]u8 = undefined;
    try client.send(.{ .seq = 999, .ack = 0, .flags = 0x02 });
    const synack_pkt = try client.nextInto(&raw, 3000);
    const synack = synack_pkt.l4.tcp;
    try std.testing.expect(synack.flags.syn and synack.flags.ack);
    try std.testing.expectEqual(@as(u32, 1000), synack.ack);
    try std.testing.expectEqual(@as(u32, 0), cap.calls.load(.acquire));

    client.rcv_nxt = synack.seq +% 1;
    try client.send(.{ .seq = 1000, .ack = client.rcv_nxt, .flags = 0x10 });
    try std.testing.expect(waitUntil(u32, &cap.calls, 1, 3000));
    try std.testing.expectEqual(@as(u16, 443), cap.meta_port.load(.acquire));

    const host_fd: sys.fd_t = @intCast(cap.sock.load(.acquire));
    defer sys.close(host_fd);
    try sys.setNonblocking(host_fd);

    // Host -> client through the socketpair and the engine's real TCP stack.
    try std.testing.expectEqual(@as(i32, 5), sys.send(host_fd, "hello", 0));
    const data_pkt = try client.nextInto(&raw, 3000);
    try std.testing.expect(data_pkt.payload_len >= 5);
    try std.testing.expectEqualStrings("hello", raw[data_pkt.payload_off..][0..5]);
    const sent_seq = data_pkt.l4.tcp.seq;
    client.rcv_nxt = sent_seq +% 5;
    try client.send(.{ .seq = 1000, .ack = client.rcv_nxt, .flags = 0x10 });

    // Client -> host. Keep the peer ACK current and poll the nonblocking fd.
    try client.send(.{ .seq = 1000, .ack = client.rcv_nxt, .flags = 0x18, .payload = "world" });
    var received: [16]u8 = undefined;
    var got: i32 = -1;
    const deadline = sys.monotonicMs() + 3000;
    while (sys.monotonicMs() < deadline) {
        got = sys.recv(host_fd, &received, 0);
        if (got > 0) break;
        sys.sleepMs(1);
    }
    try std.testing.expectEqual(@as(i32, 5), got);
    try std.testing.expectEqualStrings("world", received[0..5]);

    // Closing the host half is observed as EOF and the engine emits FIN.
    sys.close(host_fd);
    var fin_seen = false;
    const fin_deadline = sys.monotonicMs() + 3000;
    while (sys.monotonicMs() < fin_deadline and !fin_seen) {
        const p = collector.next(25, &raw) orelse continue;
        const parsed = try parse.parse(p);
        if (parsed.l4 == .tcp and parsed.l4.tcp.flags.fin) fin_seen = true;
    }
    try std.testing.expect(fin_seen);
    e.stop();
}

test "handoff setter rejects calls after start" {
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    try e.setUdpInterceptPorts(&.{443});
    try e.setTcpInterceptPorts(&.{443});
    try e.start();
    try std.testing.expectError(error.AlreadyRunning, e.setUdpInterceptPorts(&.{80}));
    try std.testing.expectError(error.AlreadyRunning, e.setTcpInterceptPorts(&.{80}));
    try std.testing.expectError(error.AlreadyRunning, e.setUdpCallback(null, null));
    try std.testing.expectError(error.AlreadyRunning, e.setTcpCallback(null, null));
    try std.testing.expectError(error.AlreadyRunning, e.setUdpFilter(null, null));
    e.stop();
}

test "Engine sendPacket and external injection report TooLarge Full and Closed" {
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    try e.setUdpCallback(UdpCapture.callback, null);
    var too_large: [4096]u8 = undefined;
    try std.testing.expectError(error.TooLarge, e.sendPacket(&too_large));
    var over_mtu: [1501]u8 = undefined;
    try std.testing.expectError(error.TooLarge, e.sendPacket(&over_mtu));
    try std.testing.expectError(error.TooLarge, e.sendPacket(&.{}));
    var packet: [16]u8 = @splat(0);
    var accepted: usize = 0;
    while (accepted < 2048) : (accepted += 1) {
        e.sendPacket(&packet) catch |err| {
            try std.testing.expectEqual(error.Full, err);
            break;
        };
    }
    try std.testing.expectEqual(@as(usize, 2048), accepted);
    try std.testing.expectError(error.Full, e.sendPacket(&packet));
    const shared = e.udp_inject orelse return error.MissingInjectQueue;
    shared.close();
    try std.testing.expectError(error.Closed, e.sendPacket(&packet));
}
