//! Small synchronous client. The compositor itself never uses this I/O path.
const std = @import("std");
const c = std.c;
const core = @import("compositor");
const max_frame = @import("control_protocol.zig").max_frame;

const usage =
    \\Usage: compo ctl [--socket PATH] [--quiet] COMMAND
    \\  list
    \\  create (--float X,Y,W,H | --tile) [options]
    \\  place WINDOW (--float X,Y,W,H | --tile) [placement options]
    \\  get|focus|raise|lower|close WINDOW
    \\  stream                 persistent NDJSON requests on stdin, replies on stdout
    \\Window targets accept a unique name, name:NAME, or an exact instance/id reference.
    \\--quiet suppresses successful replies; errors still print and exit nonzero.
    \\Options:
    \\  --name NAME --cwd PATH --shell PATH --command TEXT --focus
    \\  --target WINDOW --edge left|right|top|bottom --ratio BASIS_POINTS
    \\  --layer INTEGER --constrain
    \\  -- /absolute/program args...     direct process, no shell afterward
    \\The first tile fills the workspace; later tiles need --edge. --target splits
    \\that tile; otherwise split the whole tiled area. Ratio is the new tile share
    \\in 1..9999 basis points, default 5000. Floats use outer cell coordinates.
    \\Without --command or direct argv, create opens an interactive shell.
    \\Socket defaults to COMPO_SOCKET. Replies are JSON; server errors exit nonzero.
    \\stream performs hello once, then exchanges requests until EOF or first error.
    \\
;

const Placement = struct {
    kind: []const u8,
    rect: ?core.Rect = null,
    target: ?[]const u8 = null,
    edge: ?[]const u8 = null,
    ratio: ?u16 = null,
    layer: ?i32 = null,
    fit: ?[]const u8 = null,
};
const Request = struct {
    id: []const u8 = "ctl",
    op: []const u8,
    window: ?[]const u8 = null,
    name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    focus: ?bool = null,
    argv: ?[]const []const u8 = null,
    placement: ?Placement = null,
};
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
const Reader = struct {
    fd: c.fd_t,
    socket: bool = false,
    buffer: [4096]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    fn line(self: *Reader, out: *[max_frame]u8) !?[]const u8 {
        var used: usize = 0;
        while (true) {
            if (self.pos == self.end) {
                if (self.socket) {
                    var fds = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
                    const ready = c.poll(&fds, 1, 10000);
                    if (ready < 0 and c.errno(ready) == .INTR) continue;
                    if (ready == 0) return error.ResponseTimeout;
                    if (ready < 0) return error.ReadFailed;
                }
                const n = c.read(self.fd, &self.buffer, self.buffer.len);
                if (n < 0 and c.errno(n) == .INTR) continue;
                if (n < 0) return error.ReadFailed;
                if (n == 0) return if (used == 0) null else out[0..used];
                self.pos = 0;
                self.end = @intCast(n);
            }
            const byte = self.buffer[self.pos];
            self.pos += 1;
            if (byte == '\n') return out[0..used];
            if (used == out.len - 1) return error.FrameTooLarge;
            out[used] = byte;
            used += 1;
        }
    }
};
fn exchange(a: std.mem.Allocator, reader: *Reader, request: []const u8, output: bool) !bool {
    if (request.len + 1 > max_frame) return error.FrameTooLarge;
    const req = try std.json.parseFromSlice(std.json.Value, a, request, .{});
    defer req.deinit();
    if (req.value != .object) return error.InvalidRequest;
    const id = req.value.object.get("id") orelse return error.MissingId;
    if (id != .string) return error.InvalidId;
    try writeAll(reader.fd, request);
    try writeAll(reader.fd, "\n");
    var buffer: [max_frame]u8 = undefined;
    const response = (try reader.line(&buffer)) orelse return error.Disconnected;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const response_id = parsed.value.object.get("id") orelse return error.InvalidResponse;
    if (response_id != .string or !eql(id.string, response_id.string)) return error.InvalidResponse;
    const failed = parsed.value.object.contains("error");
    if (output or failed) {
        try writeAll(1, response);
        try writeAll(1, "\n");
    }
    return !failed;
}
fn rectangle(value: []const u8) !core.Rect {
    var parts = std.mem.splitScalar(u8, value, ',');
    var numbers: [4]i32 = undefined;
    for (&numbers) |*n| n.* = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidRect, 10);
    if (parts.next() != null) return error.InvalidRect;
    return core.Rect.init(numbers[0], numbers[1], numbers[2], numbers[3]);
}
pub fn run(a: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0 or eql(args[0], "--help") or eql(args[0], "-h")) {
        try writeAll(1, usage);
        return 0;
    }
    var path: ?[]const u8 = if (c.getenv("COMPO_SOCKET")) |v| std.mem.span(v) else null;
    var i: usize = 0;
    var quiet = false;
    while (i < args.len) {
        if (eql(args[i], "--socket")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            path = args[i];
        } else if (eql(args[i], "--quiet")) {
            quiet = true;
        } else break;
        i += 1;
    }
    if (i == args.len) return error.MissingCommand;
    const verb = args[i];
    i += 1;
    const stream = eql(verb, "stream");
    if (quiet and stream) return error.QuietStreamUnsupported;
    var request: Request = .{ .op = try std.fmt.allocPrint(a, "window.{s}", .{verb}) };
    defer a.free(request.op);
    const create = eql(verb, "create");
    const place = eql(verb, "place");
    if (!create and !eql(verb, "list") and !stream) {
        var valid = place;
        for ([_][]const u8{ "get", "focus", "raise", "lower", "close" }) |op| if (eql(op, verb)) {
            valid = true;
        };
        if (!valid) return error.UnknownCommand;
        if (i == args.len) return error.MissingWindow;
        request.window = args[i];
        i += 1;
    }
    var placement: Placement = .{ .kind = "" };
    var direct: std.ArrayList([]const u8) = .empty;
    defer direct.deinit(a);
    while (i < args.len) : (i += 1) {
        if (!create and !place) return error.UnexpectedArgument;
        const flag = args[i];
        if (eql(flag, "--") and create) {
            for (args[i + 1 ..]) |arg| try direct.append(a, arg);
            if (direct.items.len == 0) return error.MissingArgument;
            request.argv = direct.items;
            break;
        }
        if (eql(flag, "--tile") or eql(flag, "--float")) {
            if (placement.kind.len != 0) return error.DuplicatePlacement;
            placement.kind = if (eql(flag, "--tile")) "tiled" else "floating";
            if (eql(flag, "--tile")) continue;
        }
        if (eql(flag, "--focus") and create) {
            request.focus = true;
            continue;
        }
        if (eql(flag, "--constrain")) {
            placement.fit = "constrain";
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (eql(flag, "--float")) {
            placement.rect = try rectangle(value);
        } else if (eql(flag, "--target")) {
            placement.target = value;
        } else if (eql(flag, "--edge")) {
            placement.edge = value;
        } else if (eql(flag, "--ratio")) {
            placement.ratio = try std.fmt.parseInt(u16, value, 10);
        } else if (eql(flag, "--layer")) {
            placement.layer = try std.fmt.parseInt(i32, value, 10);
        } else if (create and eql(flag, "--name")) {
            request.name = value;
        } else if (create and eql(flag, "--cwd")) {
            request.cwd = value;
        } else if (create and eql(flag, "--shell")) {
            request.shell = value;
        } else if (create and eql(flag, "--command")) {
            request.command = value;
        } else return error.UnknownOption;
    }
    if (create or place) {
        if (placement.kind.len == 0) return error.MissingPlacement;
        request.placement = placement;
    }
    const socket_path = path orelse return error.MissingCompoSocket;
    var address: c.sockaddr.un = .{ .path = @splat(0) };
    if (socket_path.len == 0 or socket_path.len >= address.path.len) return error.InvalidSocketPath;
    @memcpy(address.path[0..socket_path.len], socket_path);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreate;
    defer _ = c.close(fd);
    if (@import("builtin").os.tag == .macos) {
        if (c.fcntl(fd, c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0) return error.SocketFlags;
    }
    if (c.connect(fd, @ptrCast(&address), @sizeOf(c.sockaddr.un)) < 0) return error.SocketConnect;
    var reader: Reader = .{ .fd = fd, .socket = true };
    if (!try exchange(a, &reader, "{\"id\":\"hello\",\"op\":\"hello\",\"version\":1}", false)) return 1;
    if (stream) {
        var input: Reader = .{ .fd = 0 };
        var buffer: [max_frame]u8 = undefined;
        while (try input.line(&buffer)) |line| {
            if (!try exchange(a, &reader, line, true)) return 1;
        }
    } else {
        const json = try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false });
        defer a.free(json);
        if (!try exchange(a, &reader, json, !quiet)) return 1;
    }
    return 0;
}
