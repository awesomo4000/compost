//! Wire contracts independent of sockets, PTYs and rendering.
const std = @import("std");
pub const max_frame = 64 * 1024;
pub const max_queue = 1024 * 1024;
pub const max_pending = 64;
pub const operations = [_][]const u8{ "startup.get", "startup.reload", "window.list", "window.get", "window.create", "window.place", "window.focus", "window.raise", "window.lower", "window.close" };
pub const Info = struct {
    instance: []const u8,
    columns: u16,
    rows: u16,
    dispatch: ?*const fn (std.mem.Allocator, std.json.Value, []const u8) anyerror![]u8 = null,
};
pub const Session = struct {
    ready: bool = false,
    pub fn respond(self: *Session, allocator: std.mem.Allocator, line: []const u8, info: Info) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always, .max_value_len = max_frame }) catch return failure(allocator, null, "invalid_json", "Expected a JSON object");
        defer parsed.deinit();
        if (parsed.value != .object) return failure(allocator, null, "invalid_request", "Expected a JSON object");
        const object = parsed.value.object;
        const id_value = object.get("id") orelse return failure(allocator, null, "invalid_request", "Missing request id");
        if (id_value != .string or id_value.string.len == 0 or id_value.string.len > 128) return failure(allocator, null, "invalid_request", "Request id must be 1..128 bytes");
        const id = id_value.string;
        const op = object.get("op") orelse return failure(allocator, id, "invalid_request", "Missing operation");
        if (op != .string) return failure(allocator, id, "invalid_request", "Operation must be a string");
        const hello = std.mem.eql(u8, op.string, "hello");
        var application_op = false;
        for (operations) |known| if (std.mem.eql(u8, op.string, known)) {
            application_op = true;
        };
        if (application_op and info.dispatch != null) {
            if (!self.ready) return failure(allocator, id, "handshake_required", "Send hello first");
            return info.dispatch.?(allocator, parsed.value, info.instance) catch |err| failure(allocator, id, @errorName(err), "Operation failed");
        }
        for (object.keys()) |key| {
            if (!std.mem.eql(u8, key, "id") and !std.mem.eql(u8, key, "op") and !(hello and std.mem.eql(u8, key, "version"))) return failure(allocator, id, "invalid_request", "Unknown request field");
        }
        if (hello) {
            if (self.ready) return failure(allocator, id, "already_initialized", "Handshake already completed");
            const version = object.get("version") orelse return failure(allocator, id, "invalid_request", "Missing version");
            if (version != .integer or version.integer != 1) return failure(allocator, id, "unsupported_version", "Protocol major version 1 required");
            const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .id = id, .result = .{
                .version = 1,
                .instance = info.instance,
                .operations = if (info.dispatch != null) &([_][]const u8{ "hello", "ping" } ++ operations) else &[_][]const u8{ "hello", "ping" },
                .capabilities = [_][]const u8{},
                .limits = .{ .max_frame_bytes = max_frame, .max_queue_bytes = max_queue, .max_pending_requests = max_pending },
                .root = .{ .x = 0, .y = 0, .w = info.columns, .h = info.rows },
            } }, .{});
            self.ready = true;
            return bytes;
        }
        if (!self.ready) return failure(allocator, id, "handshake_required", "Send hello first");
        if (std.mem.eql(u8, op.string, "ping")) return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .result = .{ .pong = true } }, .{});
        return failure(allocator, id, "unknown_operation", "Operation is not implemented");
    }
};
pub fn failure(allocator: std.mem.Allocator, id: ?[]const u8, code: []const u8, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .@"error" = .{ .code = code, .message = message } }, .{});
}

test "handshake errors do not initialize and JSON ids round trip" {
    const a = std.testing.allocator;
    var session: Session = .{};
    const info: Info = .{ .instance = "test", .columns = 80, .rows = 24 };
    for ([_][]const u8{ "{", "[]", "{\"id\":\"1\",\"op\":\"ping\"}", "{\"id\":\"2\",\"op\":\"hello\",\"version\":2}" }) |request| {
        const bytes = try session.respond(a, request, info);
        defer a.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "error") != null);
        try std.testing.expect(!session.ready);
    }
    const hello = try session.respond(a, "{\"id\":\"quote\\\"\\n\",\"op\":\"hello\",\"version\":1}", info);
    defer a.free(hello);
    try std.testing.expect(session.ready);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, hello, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("quote\"\n", parsed.value.object.get("id").?.string);
    const unknown = try session.respond(a, "{\"id\":\"3\",\"op\":\"ping\",\"typo\":true}", info);
    defer a.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "invalid_request") != null);
}
