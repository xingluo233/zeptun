const std = @import("std");

/// Largest number of destination ports that can be routed to the host.
pub const max_ports: u16 = 64;
/// Maximum hostname carried in one datagram disposition record.
pub const max_name: usize = 256;

pub const Error = error{ TooManyPorts, AlreadyRunning };

/// Destination port filter shared by the datagram and stream paths.
/// An empty list means every port; a fresh instance matches nothing until a
/// list is installed.
pub const PortSet = struct {
    ports: [max_ports]u16 = @splat(0),
    count: u16 = 0,
    all: bool = false,

    pub fn match(s: *const PortSet, port: u16) bool {
        if (s.all) return true;
        var i: u16 = 0;
        while (i < s.count) : (i += 1) {
            if (s.ports[i] == port) return true;
        }
        return false;
    }

    pub fn set(s: *PortSet, list: []const u16) Error!void {
        if (list.len > max_ports) return error.TooManyPorts;
        s.count = @intCast(list.len);
        s.all = list.len == 0;
        if (list.len > 0) @memcpy(s.ports[0..list.len], list);
    }

    pub fn clear(s: *PortSet) void {
        s.count = 0;
        s.all = false;
    }
};

// ── datagrams ──────────────────────────────────────────────────────────────

/// Description of one datagram handed to the host.
/// Addresses are in network byte order; IPv4 lives in the first four bytes.
pub const Meta = extern struct {
    family: u8,
    src: [16]u8,
    dst: [16]u8,
    src_port: u16,
    dst_port: u16,
    /// Offset from the packet pointer to the UDP payload.
    payload_off: u32,
    /// Length of the UDP payload.
    payload_len: u32,
    /// Domain the fake-IP address maps to, empty when unknown.
    name: [max_name]u8,
};

/// Called on a worker thread for every datagram that matches the filter.
/// The packet memory is only valid until the callback returns.
pub const Fn = *const fn (
    ctx: ?*anyopaque,
    pkt: [*]const u8,
    len: usize,
    meta: *const Meta,
) callconv(.c) void;

/// Optional second-stage filter, consulted for datagrams whose port did not
/// match. Return non-zero to take this datagram.
/// The host owns the classification rule; the engine makes no assumption about
/// what a datagram carries.
pub const Filter = *const fn (
    ctx: ?*anyopaque,
    pkt: [*]const u8,
    len: usize,
    meta: *const Meta,
) callconv(.c) c_int;

pub const State = struct {
    call: ?Fn = null,
    ctx: ?*anyopaque = null,
    filter: ?Filter = null,
    filter_ctx: ?*anyopaque = null,
    ports: PortSet = .{},

    pub inline fn active(s: *const State) bool {
        return s.call != null;
    }

    pub fn match(s: *const State, port: u16) bool {
        if (s.call == null) return false;
        return s.ports.match(port);
    }

    pub fn setPorts(s: *State, list: []const u16) Error!void {
        try s.ports.set(list);
    }

    pub fn setFilter(s: *State, f: ?Filter, ctx: ?*anyopaque) void {
        s.filter = f;
        s.filter_ctx = ctx;
    }

    pub fn clear(s: *State) void {
        s.call = null;
        s.ctx = null;
        s.filter = null;
        s.filter_ctx = null;
        s.ports.clear();
    }
};

// ── streams ────────────────────────────────────────────────────────────────

/// Description of one intercepted TCP connection.
pub const TcpMeta = extern struct {
    family: u8,
    src: [16]u8,
    dst: [16]u8,
    src_port: u16,
    dst_port: u16,
    /// Domain the fake-IP address maps to, empty when unknown.
    name: [max_name]u8,
};

/// Called on the owning worker once the client TCP handshake is complete.
/// `sock` is a blocking stream socket owned by the host. Its usize width keeps
/// the full Windows SOCKET value representable.
pub const TcpFn = *const fn (
    ctx: ?*anyopaque,
    meta: *const TcpMeta,
    sock: usize,
) callconv(.c) void;

pub const TcpState = struct {
    call: ?TcpFn = null,
    ctx: ?*anyopaque = null,
    ports: PortSet = .{},

    pub inline fn active(s: *const TcpState) bool {
        return s.call != null;
    }

    pub fn match(s: *const TcpState, port: u16) bool {
        if (s.call == null) return false;
        return s.ports.match(port);
    }

    pub fn setPorts(s: *TcpState, list: []const u16) Error!void {
        try s.ports.set(list);
    }

    pub fn clear(s: *TcpState) void {
        s.call = null;
        s.ctx = null;
        s.ports.clear();
    }
};

test "port set matches the configured list" {
    var p: PortSet = .{};
    try std.testing.expect(!p.match(443)); // nothing installed yet

    try p.set(&.{});
    try std.testing.expect(p.all);
    try std.testing.expect(p.match(443)); // empty list means every port

    try p.set(&.{ 443, 80 });
    try std.testing.expect(p.match(443));
    try std.testing.expect(p.match(80));
    try std.testing.expect(!p.match(53));

    try std.testing.expectError(error.TooManyPorts, p.set(&@as([max_ports + 1]u16, @splat(443))));

    p.clear();
    try std.testing.expect(!p.match(443));
}

test "state gates the port set on a registered callback" {
    var s: State = .{};
    try s.setPorts(&.{443});
    try std.testing.expect(!s.match(443)); // no callback yet

    const sink = struct {
        fn f(ctx: ?*anyopaque, pkt: [*]const u8, len: usize, meta: *const Meta) callconv(.c) void {
            _ = ctx;
            _ = pkt;
            _ = len;
            _ = meta;
        }
    }.f;
    s.call = sink;
    try std.testing.expect(s.active());
    try std.testing.expect(s.match(443));

    s.clear();
    try std.testing.expect(!s.active());
}

test "tcp state uses the same port rules" {
    var s: TcpState = .{};
    const sink = struct {
        fn f(ctx: ?*anyopaque, meta: *const TcpMeta, sock: usize) callconv(.c) void {
            _ = ctx;
            _ = meta;
            _ = sock;
        }
    }.f;
    s.call = sink;
    try s.setPorts(&.{443});
    try std.testing.expect(s.match(443));
    try std.testing.expect(!s.match(22));

    try s.setPorts(&.{});
    try std.testing.expect(s.match(22)); // every port

    s.clear();
    try std.testing.expect(!s.active());
}

test "maximum port list is rejected consistently" {
    var ports: PortSet = .{};
    try std.testing.expectError(error.TooManyPorts, ports.set(&@as([max_ports + 1]u16, @splat(1))));
}

test "meta layouts are C compatible" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Meta, "family"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(Meta, "src"));
    try std.testing.expectEqual(@as(usize, 17), @offsetOf(Meta, "dst"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(Meta, "src_port"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(Meta, "dst_port"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Meta, "payload_off"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(Meta, "payload_len"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Meta, "name"));
    try std.testing.expectEqual(@as(usize, 48 + max_name), @sizeOf(Meta));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TcpMeta, "family"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(TcpMeta, "src"));
    try std.testing.expectEqual(@as(usize, 17), @offsetOf(TcpMeta, "dst"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(TcpMeta, "src_port"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(TcpMeta, "dst_port"));
    try std.testing.expectEqual(@as(usize, 38), @offsetOf(TcpMeta, "name"));
    try std.testing.expectEqual(@as(usize, 38 + max_name), @sizeOf(TcpMeta));
}
