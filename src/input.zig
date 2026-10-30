//! Incremental outer-terminal input framing, independent of PTYs and window policy.
const std = @import("std");
pub const Mouse = struct { button: u16, x: u16, y: u16, release: bool };
pub const Event = union(enum) { bytes: []const u8, mouse: Mouse, toggle_focus, toggle_float, new_shell, scrollback, select_mode, copy_selection, reload, quit, help, numbers, focus_number: u8, focus: bool };
pub const Sink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Event) anyerror!void };
pub const Binding = struct { key: u8, label: []const u8, description: []const u8, event: Event };
pub const bindings = [_]Binding{
    .{ .key = '\r', .label = "Enter", .description = "new shell", .event = .new_shell },
    .{ .key = '\t', .label = "Tab", .description = "focus next window", .event = .toggle_focus },
    .{ .key = 'f', .label = "f", .description = "toggle floating window", .event = .toggle_float },
    .{ .key = '[', .label = "[", .description = "scrollback", .event = .scrollback },
    .{ .key = 'c', .label = "c", .description = "select mode", .event = .select_mode },
    .{ .key = 'y', .label = "y", .description = "copy selection", .event = .copy_selection },
    .{ .key = 'r', .label = "r", .description = "reload startup script", .event = .reload },
    .{ .key = 'n', .label = "n", .description = "toggle window numbers", .event = .numbers },
    .{ .key = '/', .label = "/ or ?", .description = "toggle help", .event = .help },
    .{ .key = 'q', .label = "q", .description = "quit", .event = .quit },
};

/// A single control byte; Escape is reserved for terminal sequence framing.
pub const Prefix = struct {
    byte: u8 = 0x1d,

    pub fn parse(name: []const u8) !Prefix {
        const key = if (std.ascii.startsWithIgnoreCase(name, "Ctrl-")) name[5..] else if (std.ascii.startsWithIgnoreCase(name, "C-")) name[2..] else return error.InvalidPrefix;
        if (key.len != 1) return error.InvalidPrefix;
        const letter = std.ascii.toUpper(key[0]);
        if (letter < '@' or letter > '_' or letter == '[') return error.InvalidPrefix;
        return .{ .byte = letter & 0x1f };
    }

    pub fn label(self: Prefix) [6]u8 {
        return .{ 'C', 't', 'r', 'l', '-', if (self.byte >= 1 and self.byte <= 26) self.byte + 'a' - 1 else self.byte + '@' };
    }
};

pub const Decoder = struct {
    pending: [128]u8 = undefined,
    len: usize = 0,
    prefix: bool = false,
    prefix_key: Prefix = .{},
    pasting: bool = false,

    pub fn feed(self: *Decoder, bytes: []const u8, sink: Sink) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            index += 1;
            // Keep ordinary typing and paste payloads batched for the PTY writer.
            if (self.len == 0 and !self.prefix and byte != 0x1b and (self.pasting or byte != self.prefix_key.byte)) {
                const start = index - 1;
                while (index < bytes.len and bytes[index] != 0x1b and (self.pasting or bytes[index] != self.prefix_key.byte)) : (index += 1) {}
                try sink.emit(sink.context, .{ .bytes = bytes[start..index] });
                continue;
            }
            if (self.len != 0) {
                if (self.len == self.pending.len) try self.flush(sink);
                self.pending[self.len] = byte;
                self.len += 1;
                // Application cursor keys use SS3 (ESC O A/B/C/D). Keep the
                // introducer with its final byte just as we do for CSI keys.
                if (self.len == 2 and byte != '[' and byte != 'O') {
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
                if (byte == self.prefix_key.byte) {
                    try sink.emit(sink.context, .{ .bytes = &.{self.prefix_key.byte} });
                    continue;
                }
                if (byte >= '0' and byte <= '9') {
                    try sink.emit(sink.context, .{ .focus_number = if (byte == '0') 10 else byte - '0' });
                    continue;
                }
                const key = if (byte == '\n') '\r' else if (byte == '?') '/' else byte;
                var matched = false;
                for (bindings) |binding| if (binding.key == key) {
                    try sink.emit(sink.context, binding.event);
                    matched = true;
                    break;
                };
                if (matched) continue;
                try sink.emit(sink.context, .{ .bytes = &.{self.prefix_key.byte} });
            }
            if (!self.pasting and byte == self.prefix_key.byte) {
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
    /// Only a lone Escape needs a timeout to distinguish it from a key sequence.
    /// Once CSI/SS3 has begun, a delay between reads must not split the key.
    pub fn idle(self: *Decoder, sink: Sink) !void {
        if (self.len == 1) try self.flush(sink);
    }
    /// Explicit recovery for an unrecognized or oversized sequence.
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
                .help, .numbers, .focus_number, .focus, .toggle_float, .new_shell, .scrollback, .select_mode, .copy_selection, .reload, .quit => {},
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

test "CSI and SS3 keys remain atomic across reads and idle gaps" {
    const Recorder = struct {
        expected: []const u8,
        calls: usize = 0,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .bytes => |bytes| {
                    try std.testing.expectEqualStrings(self.expected, bytes);
                    self.calls += 1;
                },
                else => return error.UnexpectedEvent,
            }
        }
    };
    for ([_][]const u8{ "\x1bOA", "\x1bOB", "\x1bOC", "\x1bOD", "\x1bOP", "\x1b[A", "\x1b[D", "\x1b[1;5D", "\x1b[57350;1:2u" }) |key| {
        for (1..key.len) |split| {
            var decoder: Decoder = .{};
            var recorder: Recorder = .{ .expected = key };
            const sink: Sink = .{ .context = &recorder, .emit = Recorder.emit };
            try decoder.feed(key[0..split], sink);
            if (split >= 2) {
                try decoder.idle(sink);
                try decoder.idle(sink);
            }
            try std.testing.expectEqual(@as(usize, 0), recorder.calls);
            try decoder.feed(key[split..], sink);
            try std.testing.expectEqual(@as(usize, 1), recorder.calls);
            for (0..1000) |_| try decoder.feed(key, sink);
            try std.testing.expectEqual(@as(usize, 1001), recorder.calls);
        }
    }
    var decoder: Decoder = .{};
    var recorder: Recorder = .{ .expected = "\x1b" };
    const sink: Sink = .{ .context = &recorder, .emit = Recorder.emit };
    try decoder.feed("\x1b", sink);
    try decoder.idle(sink);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
}

test "configured prefix routes shortcuts, literals, unknown keys and paste" {
    const Recorder = struct {
        bytes: std.ArrayList(u8) = .empty,
        toggles: usize = 0,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .bytes => |bytes| try self.bytes.appendSlice(std.testing.allocator, bytes),
                .toggle_focus => self.toggles += 1,
                else => return error.UnexpectedEvent,
            }
        }
    };
    var recorder: Recorder = .{};
    defer recorder.bytes.deinit(std.testing.allocator);
    var decoder: Decoder = .{ .prefix_key = try Prefix.parse("C-a") };
    const sink: Sink = .{ .context = &recorder, .emit = Recorder.emit };
    for ("\x01\t\x01\x01\x01z\x1d\x1b[200~\x01\t\x1b[201~") |byte| try decoder.feed(&.{byte}, sink);
    try std.testing.expectEqual(@as(usize, 1), recorder.toggles);
    try std.testing.expectEqualStrings("\x01\x01z\x1d\x1b[200~\x01\t\x1b[201~", recorder.bytes.items);
    decoder.prefix_key = try Prefix.parse("Ctrl-i");
    try decoder.feed("\t\t", sink);
    try std.testing.expectEqual(@as(usize, 1), recorder.toggles);
    try std.testing.expectEqual(@as(u8, '\t'), recorder.bytes.items[recorder.bytes.items.len - 1]);
}

test "prefix parsing and display labels" {
    for ([_][]const u8{ "C-a", "Ctrl-A", "ctrl-a" }) |name| {
        const key = try Prefix.parse(name);
        try std.testing.expectEqual(@as(u8, 1), key.byte);
        try std.testing.expectEqualStrings("Ctrl-a", &key.label());
    }
    try std.testing.expectEqualStrings("Ctrl-]", &(Prefix{}).label());
    for ([_][]const u8{ "", "a", "Alt-a", "Ctrl-[", "Ctrl-aa", "Ctrl-?" }) |name| try std.testing.expectError(error.InvalidPrefix, Prefix.parse(name));
}

test "every advertised binding dispatches and keys are unique" {
    const Recorder = struct {
        expected: Event,
        count: usize = 0,
        fn emit(ctx: *anyopaque, event: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqualDeep(self.expected, event);
            self.count += 1;
        }
    };
    for (bindings, 0..) |binding, i| {
        for (bindings[i + 1 ..]) |other| try std.testing.expect(binding.key != other.key);
        var decoder: Decoder = .{};
        var recorder: Recorder = .{ .expected = binding.event };
        try decoder.feed(&.{ decoder.prefix_key.byte, binding.key }, .{ .context = &recorder, .emit = Recorder.emit });
        try std.testing.expectEqual(@as(usize, 1), recorder.count);
    }
    for ("1234567890?", 0..) |key, i| {
        var decoder: Decoder = .{};
        var recorder: Recorder = .{ .expected = if (key == '?') .help else .{ .focus_number = @intCast(i + 1) } };
        try decoder.feed(&.{ decoder.prefix_key.byte, key }, .{ .context = &recorder, .emit = Recorder.emit });
        try std.testing.expectEqual(@as(usize, 1), recorder.count);
    }
}
