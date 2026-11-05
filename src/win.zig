//! Native Windows declarations and UTF-8 boundary helpers.
const std = @import("std");
pub const c = @import("winapi");
pub const a = std.heap.smp_allocator;
pub fn wide(text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, text);
}
pub fn writeAll(handle: c.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: c.DWORD = 0;
        if (c.WriteFile(handle, bytes[offset..].ptr, @intCast(@min(bytes.len - offset, 65536)), &written, null) == 0 or written == 0) return error.WriteFailed;
        offset += written;
    }
}
pub fn stderrWrite(bytes: []const u8) isize {
    writeAll(c.GetStdHandle(c.STD_ERROR_HANDLE), bytes) catch return -1;
    return @intCast(bytes.len);
}
pub fn stderrIsTerminal() bool {
    var mode: c.DWORD = 0;
    return c.GetConsoleMode(c.GetStdHandle(c.STD_ERROR_HANDLE), &mode) != 0;
}
pub fn cwd(buffer: []u8) ?[*]u8 {
    var path: [32768]u16 = undefined;
    const len = c.GetCurrentDirectoryW(path.len, &path);
    if (len == 0 or len >= path.len) return null;
    const result = std.unicode.utf16LeToUtf8(buffer, path[0..len]) catch return null;
    if (result == buffer.len) return null;
    buffer[result] = 0;
    return buffer.ptr;
}
pub fn setEnv(name: []const u8, value: ?[]const u8) !void {
    const n = try wide(name);
    defer a.free(n);
    const v = if (value) |text| try wide(text) else null;
    defer if (v) |text| a.free(text);
    if (c.SetEnvironmentVariableW(n.ptr, if (v) |text| text.ptr else null) == 0) return error.EnvironmentFailed;
}
/// Quote one argument using the Windows CRT argv rules, including trailing slashes.
pub fn commandLine(args: []const []const u8) ![:0]u16 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (args, 0..) |arg, index| {
        if (index > 0) try out.writer.writeByte(' ');
        // cmd parses its command as shell text, not as a CRT argv argument.
        // /S strips these outer quotes; preserve quotes inside the command.
        if (index > 0 and std.ascii.eqlIgnoreCase(std.fs.path.basename(args[0]), "cmd.exe")) {
            if (std.ascii.eqlIgnoreCase(args[index - 1], "/K") or std.ascii.eqlIgnoreCase(args[index - 1], "/C")) {
                try out.writer.writeByte('"');
                try out.writer.writeAll(arg);
                try out.writer.writeByte('"');
                continue;
            }
            try out.writer.writeAll(arg);
            continue;
        }
        try out.writer.writeByte('"');
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            try out.writer.splatByteAll('\\', slashes * (if (byte == '"') @as(usize, 2) else 1));
            slashes = 0;
            if (byte == '"') try out.writer.writeByte('\\');
            try out.writer.writeByte(byte);
        }
        try out.writer.splatByteAll('\\', slashes * 2);
        try out.writer.writeByte('"');
    }
    return wide(out.written());
}
/// Build a private UTF-16 environment block; never mutate the compositor environment.
pub fn environment(extra: std.json.ArrayHashMap([]const u8)) ![]u16 {
    const native = c.GetEnvironmentStringsW() orelse return error.EnvironmentFailed;
    defer _ = c.FreeEnvironmentStringsW(native);
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(a);
    var offset: usize = 0;
    while (native[offset] != 0) {
        const start = offset;
        while (native[offset] != 0) : (offset += 1) {}
        const item = native[start..offset];
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(a, item);
        defer a.free(utf8);
        const eq = std.mem.indexOfScalarPos(u8, utf8, 1, '=') orelse utf8.len;
        var overridden = false;
        for (extra.map.keys()) |key| if (std.ascii.eqlIgnoreCase(key, utf8[0..eq])) {
            overridden = true;
            break;
        };
        if (!overridden) {
            try out.appendSlice(a, item);
            try out.append(a, 0);
        }
        offset += 1;
    }
    for (extra.map.keys(), extra.map.values()) |key, value| {
        const text = try std.fmt.allocPrint(a, "{s}={s}", .{ key, value });
        defer a.free(text);
        const item = try wide(text);
        defer a.free(item);
        try out.appendSlice(a, item);
        try out.append(a, 0);
    }
    try out.append(a, 0);
    return out.toOwnedSlice(a);
}
