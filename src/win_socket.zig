//! Winsock AF_UNIX adapter for the shared control protocol and CLI.
const std = @import("std");
const win = @import("win.zig");
const w = win.c;
pub const fd_t = isize;
pub const AF = struct {
    pub const UNIX = 1;
};
pub const SOCK = struct {
    pub const STREAM = 1;
};
pub const POLL = struct {
    pub const IN: c_short = 0x300;
    pub const OUT: c_short = 0x10;
    pub const ERR: c_short = 1;
    pub const HUP: c_short = 2;
    pub const NVAL: c_short = 4;
};
pub const pollfd = extern struct { fd: fd_t, events: c_short, revents: c_short };
pub const sockaddr = struct {
    pub const un = extern struct { family: u16 = 1, path: [108]u8 };
};
pub const getenv = std.c.getenv;
extern "c" fn _read(c_int, [*]u8, c_uint) c_int;
extern "c" fn _write(c_int, [*]const u8, c_uint) c_int;
extern "c" fn _errno() *c_int;
var started = false;
var last_error: c_int = 0;
pub fn errno(_: anytype) enum { AGAIN, INTR, OTHER } {
    return switch (last_error) {
        10035, 11 => .AGAIN,
        10004, 4 => .INTR,
        else => .OTHER,
    };
}
pub fn socket(af: c_int, kind: c_int, protocol: c_int) fd_t {
    if (!started) {
        var data: w.WSADATA = undefined;
        if (w.WSAStartup(0x202, &data) != 0) return -1;
        started = true;
    }
    const result = w.WSASocketW(af, kind, protocol, null, 0, 0x80);
    return @bitCast(result);
}
pub fn nonblock(fd: fd_t) !void {
    var on: c_ulong = 1;
    if (w.ioctlsocket(@bitCast(fd), @bitCast(@as(u32, 0x8004667e)), &on) != 0) return error.SocketFlags;
}
pub fn close(fd: fd_t) c_int {
    return w.closesocket(@bitCast(fd));
}
pub fn bind(fd: fd_t, address: *const anyopaque, len: usize) c_int {
    return w.bind(@bitCast(fd), @ptrCast(@alignCast(address)), @intCast(len));
}
pub fn connect(fd: fd_t, address: *const anyopaque, len: usize) c_int {
    return w.connect(@bitCast(fd), @ptrCast(@alignCast(address)), @intCast(len));
}
pub fn listen(fd: fd_t, backlog: c_int) c_int {
    return w.listen(@bitCast(fd), backlog);
}
pub fn accept(fd: fd_t, _: ?*anyopaque, _: ?*anyopaque) fd_t {
    return @bitCast(w.accept(@bitCast(fd), null, null));
}
pub fn poll(fds: [*]pollfd, count: usize, timeout: c_int) c_int {
    const result = w.WSAPoll(@ptrCast(fds), @intCast(count), timeout);
    if (result < 0) last_error = w.WSAGetLastError();
    return result;
}
pub fn read(fd: fd_t, buffer: [*]u8, len: usize) isize {
    if (fd < 3) {
        const result = _read(@intCast(fd), buffer, @intCast(len));
        if (result < 0) last_error = _errno().*;
        return result;
    }
    const result = w.recv(@bitCast(fd), @ptrCast(buffer), @intCast(len), 0);
    if (result < 0) last_error = w.WSAGetLastError();
    return result;
}
pub fn write(fd: fd_t, buffer: [*]const u8, len: usize) isize {
    if (fd < 3) {
        const result = _write(@intCast(fd), buffer, @intCast(len));
        if (result < 0) last_error = _errno().*;
        return result;
    }
    const result = w.send(@bitCast(fd), @ptrCast(buffer), @intCast(len), 0);
    if (result < 0) last_error = w.WSAGetLastError();
    return result;
}
pub fn unlink(path: [*:0]const u8) c_int {
    const p = win.wide(std.mem.span(path)) catch return -1;
    defer win.a.free(p);
    return if (w.DeleteFileW(p.ptr) != 0) 0 else -1;
}
pub fn rmdir(path: [*:0]const u8) c_int {
    const p = win.wide(std.mem.span(path)) catch return -1;
    defer win.a.free(p);
    return if (w.RemoveDirectoryW(p.ptr) != 0) 0 else -1;
}
pub fn chmod(_: [*:0]const u8, _: c_int) c_int {
    return 0;
} // Access is inherited from the private user temp directory.
pub fn random(bytes: []u8) !void {
    if (w.BCryptGenRandom(null, bytes.ptr, @intCast(bytes.len), 2) < 0) return error.RandomFailed;
}
pub fn directory(buffer: []u8, instance: []const u8) !void {
    var temp: [260]u16 = undefined;
    const len = w.GetTempPathW(temp.len, &temp);
    if (len == 0 or len >= temp.len) return error.SocketDirectory;
    const path = try std.unicode.utf16LeToUtf8Alloc(win.a, temp[0..len]);
    defer win.a.free(path);
    const text = try std.mem.print(buffer, "{s}compo-{s}", .{ path, instance[0..12] });
    buffer[text.len] = 0;
    const native = try win.wide(text);
    defer win.a.free(native);
    if (w.CreateDirectoryW(native.ptr, null) == 0) return error.SocketDirectory;
}
