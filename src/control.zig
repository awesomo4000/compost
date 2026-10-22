//! Nonblocking local control transport. Called only by the host event loop.
const std = @import("std");
const c = std.c;
const protocol = @import("control_protocol.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn arc4random_buf([*]u8, usize) void;
const allocator = std.heap.smp_allocator;
pub const max_clients = 8;
pub const poll_count = max_clients + 1;
const Pending = struct { id: []u8, end: usize };
const Client = struct {
    fd: c.fd_t,
    session: protocol.Session = .{},
    input: [protocol.max_frame]u8 = undefined,
    used: usize = 0,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    fn deinit(self: *Client) void {
        _ = c.close(self.fd);
        for (self.pending.items) |p| allocator.free(p.id);
        self.pending.deinit(allocator);
        self.output.deinit(allocator);
        allocator.destroy(self);
    }
    fn dispatch(self: *Client, line: []const u8, info: protocol.Info) !void {
        // IDs remain in flight until their response is written to the socket.
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{ .max_value_len = protocol.max_frame }) catch null;
        defer if (parsed) |p| p.deinit();
        var id: ?[]const u8 = null;
        if (parsed) |p| if (p.value == .object) {
            if (p.value.object.get("id")) |value| if (value == .string and value.string.len > 0 and value.string.len <= 128) {
                id = value.string;
            };
        };
        if (id) |request_id| {
            for (self.pending.items) |pending| if (std.mem.eql(u8, pending.id, request_id)) return error.DuplicateId;
        }
        if (self.pending.items.len >= protocol.max_pending) return error.SlowConsumer;
        const response = try self.session.respond(allocator, line, info);
        defer allocator.free(response);
        if (self.output.items.len + response.len + 1 > protocol.max_queue) return error.SlowConsumer;
        try self.output.appendSlice(allocator, response);
        try self.output.append(allocator, '\n');
        if (id) |request_id| {
            const owned = try allocator.dupe(u8, request_id);
            errdefer allocator.free(owned);
            try self.pending.append(allocator, .{ .id = owned, .end = self.output.items.len });
        }
    }
    fn readReady(self: *Client, info: protocol.Info) !void {
        var bytes: [16384]u8 = undefined;
        const n = c.read(self.fd, &bytes, bytes.len);
        if (n < 0 and (c.errno(n) == .AGAIN or c.errno(n) == .INTR)) return;
        if (n <= 0) return error.Disconnected;
        for (bytes[0..@intCast(n)]) |byte| {
            if (byte == '\n') {
                try self.dispatch(self.input[0..self.used], info);
                self.used = 0;
            } else {
                if (self.used == self.input.len - 1) return error.FrameTooLarge;
                self.input[self.used] = byte;
                self.used += 1;
            }
        }
    }
    fn writeReady(self: *Client) !void {
        if (self.sent == self.output.items.len) return;
        const bytes = self.output.items[self.sent..];
        const n = c.write(self.fd, bytes.ptr, bytes.len);
        if (n < 0 and (c.errno(n) == .AGAIN or c.errno(n) == .INTR)) return;
        if (n <= 0) return error.Disconnected;
        self.sent += @intCast(n);
        var finished: usize = 0;
        for (self.pending.items) |pending| {
            if (pending.end > self.sent) break;
            allocator.free(pending.id);
            finished += 1;
        }
        const remaining = self.pending.items.len - finished;
        std.mem.copyForwards(Pending, self.pending.items[0..remaining], self.pending.items[finished..]);
        self.pending.items.len = remaining;
        const queued = self.output.items.len - self.sent;
        std.mem.copyForwards(u8, self.output.items[0..queued], self.output.items[self.sent..]);
        self.output.items.len = queued;
        for (self.pending.items) |*pending| pending.end -= self.sent;
        self.sent = 0;
    }
};
fn prepare(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    const nonblock: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, 1)) < 0) return error.SocketFlags;
    if (@import("builtin").os.tag == .macos) {
        if (c.fcntl(fd, c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0) return error.SocketFlags;
    }
}
pub const Server = struct {
    listener: c.fd_t = -1,
    directory: [32:0]u8 = @splat(0),
    path: [104:0]u8 = @splat(0),
    instance: [32]u8 = undefined,
    clients: [max_clients]?*Client = @splat(null),
    pub fn init() !Server {
        var self: Server = .{};
        const template = "/tmp/compo-XXXXXX";
        @memcpy(self.directory[0..template.len], template);
        if (mkdtemp(&self.directory) == null) return error.SocketDirectory;
        errdefer _ = c.rmdir(&self.directory);
        _ = try std.mem.print(&self.path, "{s}/control.sock", .{std.mem.sliceTo(&self.directory, 0)});
        var random: [16]u8 = undefined;
        arc4random_buf(&random, random.len);
        self.instance = std.fmt.bytesToHex(random, .lower);
        self.listener = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (self.listener < 0) return error.SocketCreate;
        errdefer _ = c.close(self.listener);
        try prepare(self.listener);
        var address: c.sockaddr.un = .{ .path = @splat(0) };
        const path = std.mem.sliceTo(&self.path, 0);
        @memcpy(address.path[0..path.len], path);
        if (c.bind(self.listener, @ptrCast(&address), @sizeOf(c.sockaddr.un)) < 0) return error.SocketBind;
        errdefer _ = c.unlink(&self.path);
        if (c.chmod(&self.path, 0o600) < 0 or c.listen(self.listener, max_clients) < 0) return error.SocketListen;
        return self;
    }
    pub fn deinit(self: *Server) void {
        for (&self.clients) |*client| if (client.*) |p| {
            p.deinit();
            client.* = null;
        };
        if (self.listener >= 0) _ = c.close(self.listener);
        _ = c.unlink(&self.path);
        _ = c.rmdir(&self.directory);
    }
    pub fn pollfds(self: *const Server, fds: []c.pollfd) void {
        fds[0] = .{ .fd = self.listener, .events = c.POLL.IN, .revents = 0 };
        for (self.clients, fds[1..]) |client, *fd| fd.* = .{ .fd = if (client) |p| p.fd else -1, .events = c.POLL.IN | (if (client != null and client.?.output.items.len > client.?.sent) @as(c_short, c.POLL.OUT) else 0), .revents = 0 };
    }
    pub fn service(self: *Server, fds: []const c.pollfd, columns: u16, rows: u16) void {
        // Service existing clients before accepting, so stale poll bits cannot
        // be applied to a descriptor newly assigned to a recycled client slot.
        for (&self.clients, fds[1..]) |*maybe, fd| if (maybe.*) |client| {
            const result: ?anyerror = blk: {
                if (fd.revents & (c.POLL.ERR | c.POLL.NVAL | c.POLL.HUP) != 0) break :blk error.Disconnected;
                if (fd.revents & c.POLL.IN != 0) client.readReady(.{ .instance = &self.instance, .columns = columns, .rows = rows }) catch |err| break :blk err;
                if (fd.revents & c.POLL.OUT != 0) client.writeReady() catch |err| break :blk err;
                break :blk null;
            };
            if (result != null) {
                client.deinit();
                maybe.* = null;
            }
        };
        if (fds[0].revents & c.POLL.IN != 0) {
            const fd = c.accept(self.listener, null, null);
            if (fd < 0) return;
            prepare(fd) catch {
                _ = c.close(fd);
                return;
            };
            for (&self.clients) |*slot| if (slot.* == null) {
                const client = allocator.create(Client) catch {
                    _ = c.close(fd);
                    return;
                };
                client.* = .{ .fd = fd };
                slot.* = client;
                return;
            };
            _ = c.close(fd);
        }
    }
};
