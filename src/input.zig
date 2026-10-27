//! Incremental outer-terminal input framing, independent of PTYs and window policy.
const std = @import("std");
pub const Mouse = struct { button: u16, x: u16, y: u16, release: bool };
pub const Event = union(enum) { bytes: []const u8, mouse: Mouse, toggle_focus, toggle_float, new_shell, scrollback, quit, focus: bool };
pub const Sink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Event) anyerror!void };
pub const Decoder = struct {
    pending: [128]u8 = undefined,
    len: usize = 0,
    prefix: bool = false,
    pasting: bool = false,

    pub fn feed(self: *Decoder, bytes: []const u8, sink: Sink) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            index += 1;
            // Keep ordinary typing and paste payloads batched for the PTY writer.
            if (self.len == 0 and !self.prefix and byte != 0x1b and (self.pasting or byte != 0x1d)) {
                const start = index - 1;
                while (index < bytes.len and bytes[index] != 0x1b and (self.pasting or bytes[index] != 0x1d)) : (index += 1) {}
                try sink.emit(sink.context, .{ .bytes = bytes[start..index] });
                continue;
            }
            if (self.len != 0) {
                if (self.len == self.pending.len) try self.flush(sink);
                self.pending[self.len] = byte;
                self.len += 1;
                if (self.len == 2 and byte != '[') {
                    try self.flush(sink);
                    continue;
                }
                if (self.len >= 3 and byte >= 0x40 and byte <= 0x7e) {
                    const sequence = self.pending[0..self.len];
                    if (std.mem.eql(u8, sequence, "\x1b[200~")) {
                        self.pasting = true;
                        try sink.emit(sink.context, .{ .bytes = sequence });
                    } else if (std.mem.eql(u8, sequence, "\x1b[201~")) {
                        self.pasting = false;
                        try sink.emit(sink.context, .{ .bytes = sequence });
                    } else if (!self.pasting and parseMouse(sequence) != null) {
                        try sink.emit(sink.context, .{ .mouse = parseMouse(sequence).? });
                    } else if (!self.pasting and (std.mem.eql(u8, sequence, "\x1b[I") or std.mem.eql(u8, sequence, "\x1b[O"))) {
                        try sink.emit(sink.context, .{ .focus = sequence[2] == 'I' });
                    } else try sink.emit(sink.context, .{ .bytes = sequence });
                    self.len = 0;
                }
                continue;
            }
            if (!self.pasting and self.prefix) {
                self.prefix = false;
                if (byte == '\t') {
                    try sink.emit(sink.context, .toggle_focus);
                    continue;
                }
                if (byte == '\r' or byte == '\n') {
                    try sink.emit(sink.context, .new_shell);
                    continue;
                }
                if (byte == '[') {
                    try sink.emit(sink.context, .scrollback);
                    continue;
                }
                if (byte == 'q') {
                    try sink.emit(sink.context, .quit);
                    continue;
                }
                if (byte == 'f') {
                    try sink.emit(sink.context, .toggle_float);
                    continue;
                }
                try sink.emit(sink.context, .{ .bytes = "\x1d" });
                if (byte == 0x1d) continue;
            }
            if (!self.pasting and byte == 0x1d) {
                self.prefix = true;
                continue;
            }
            if (byte == 0x1b) {
                self.pending[0] = byte;
                self.len = 1;
                continue;
            }
            const single = [_]u8{byte};
            try sink.emit(sink.context, .{ .bytes = &single });
        }
    }
    /// A short idle timeout forwards standalone Escape and incomplete sequences.
    pub fn flush(self: *Decoder, sink: Sink) !void {
        if (self.len != 0) try sink.emit(sink.context, .{ .bytes = self.pending[0..self.len] });
        self.len = 0;
    }
    fn parseMouse(bytes: []const u8) ?Mouse {
        if (bytes.len < 9 or !std.mem.startsWith(u8, bytes, "\x1b[<")) return null;
        const end = bytes[bytes.len - 1];
        if (end != 'M' and end != 'm') return null;
        var parts = std.mem.splitScalar(u8, bytes[3 .. bytes.len - 1], ';');
        const button = std.fmt.parseInt(u16, parts.next() orelse return null, 10) catch return null;
        const x = std.fmt.parseInt(u16, parts.next() orelse return null, 10) catch return null;
        const y = std.fmt.parseInt(u16, parts.next() orelse return null, 10) catch return null;
        if (parts.next() != null or x == 0 or y == 0) return null;
        return .{ .button = button, .x = x - 1, .y = y - 1, .release = end == 'm' };
    }
};

test "fragmented mouse, focus shortcut, paste, and Escape framing" {
    const Recorder = struct {
        bytes: std.ArrayList(u8) = .empty,
        mouse: ?Mouse = null,
        toggles: usize = 0,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .bytes => |bytes| try self.bytes.appendSlice(std.testing.allocator, bytes),
                .mouse => |mouse| self.mouse = mouse,
                .toggle_focus => self.toggles += 1,
                .focus, .toggle_float, .new_shell, .scrollback, .quit => {},
            }
        }
    };
    var recorder: Recorder = .{};
    defer recorder.bytes.deinit(std.testing.allocator);
    var decoder: Decoder = .{};
    const sink: Sink = .{ .context = &recorder, .emit = Recorder.emit };
    for ("\x1b[<0;26;4M") |byte| try decoder.feed(&.{byte}, sink);
    try std.testing.expectEqual(Mouse{ .button = 0, .x = 25, .y = 3, .release = false }, recorder.mouse.?);
    try decoder.feed("\x1d\t\x1d\x1d\x1b[200~\x1d\t\x1b[201~\x1b", sink);
    try decoder.flush(sink);
    try std.testing.expectEqual(@as(usize, 1), recorder.toggles);
    try std.testing.expectEqualStrings("\x1d\x1b[200~\x1d\t\x1b[201~\x1b", recorder.bytes.items);
}
