//! Native ConPTY host. Worker threads move pipe bytes; only the main thread owns VT/UI state.
pub var default_shell: ?[:0]const u8 = null;
const std = @import("std");
const win = @import("win.zig");
const w = win.c;
const app = @import("root");
const control = @import("control.zig");
const net = @import("win_socket.zig");
const startup = @import("startup_windows.zig");
const a = std.heap.smp_allocator;
pub const capacity = 32;
pub var desktop = false;
pub var startup_script: ?[:0]const u8 = null;
pub var startup_directory: ?[:0]const u8 = null;
pub var startup_binary: [:0]const u8 = "";
pub var startup_phase: enum { initial, idle, validating, reloading } = .initial;
var startup_job: ?startup.Job = null;
var server: ?control.Server = null;
var children: [capacity]?*Child = @splat(null);
var sizes: [capacity]w.COORD = @splat(.{ .X = 80, .Y = 24 });
var quit_requested = std.atomic.Value(bool).init(false);
var headless = false;
var count: usize = 0;
var main_status: c_int = 0;
var root_size: w.COORD = .{ .X = 80, .Y = 24 };

const Queue = struct {
    lock: w.CRITICAL_SECTION = undefined,
    wake: w.HANDLE = null,
    bytes: [128 * 1024]u8 = undefined,
    used: usize = 0,
    stopped: bool = false,
    eof: bool = false,
    fn init(self: *Queue) !void {
        w.InitializeCriticalSection(&self.lock);
        self.wake = w.CreateEventW(null, 0, 0, null);
        if (self.wake == null) {
            w.DeleteCriticalSection(&self.lock);
            return error.EventFailed;
        }
    }
    fn deinit(self: *Queue) void {
        _ = w.CloseHandle(self.wake);
        w.DeleteCriticalSection(&self.lock);
    }
    fn stop(self: *Queue) void {
        w.EnterCriticalSection(&self.lock);
        self.stopped = true;
        w.LeaveCriticalSection(&self.lock);
        _ = w.SetEvent(self.wake);
    }
    fn done(self: *Queue) void {
        w.EnterCriticalSection(&self.lock);
        self.eof = true;
        w.LeaveCriticalSection(&self.lock);
        _ = w.SetEvent(self.wake);
    }
    fn drained(self: *Queue) bool {
        w.EnterCriticalSection(&self.lock);
        defer w.LeaveCriticalSection(&self.lock);
        return self.eof and self.used == 0;
    }
    fn put(self: *Queue, data: []const u8, wait: bool) bool {
        while (true) {
            w.EnterCriticalSection(&self.lock);
            if (self.stopped) {
                w.LeaveCriticalSection(&self.lock);
                return false;
            }
            if (data.len <= self.bytes.len - self.used) {
                @memcpy(self.bytes[self.used..][0..data.len], data);
                self.used += data.len;
                w.LeaveCriticalSection(&self.lock);
                _ = w.SetEvent(self.wake);
                return true;
            }
            w.LeaveCriticalSection(&self.lock);
            if (!wait) return false;
            _ = w.WaitForSingleObject(self.wake, 50);
        }
    }
    fn take(self: *Queue, out: []u8) usize {
        w.EnterCriticalSection(&self.lock);
        defer w.LeaveCriticalSection(&self.lock);
        const n = @min(out.len, self.used);
        @memcpy(out[0..n], self.bytes[0..n]);
        std.mem.copyForwards(u8, self.bytes[0 .. self.used - n], self.bytes[n..self.used]);
        self.used -= n;
        if (n > 0) _ = w.SetEvent(self.wake);
        return n;
    }
};
const Child = struct {
    pc: w.HPCON = null,
    process: w.HANDLE = null,
    job: w.HANDLE = null,
    input: w.HANDLE = null,
    output: w.HANDLE = null,
    incoming: Queue = .{},
    outgoing: Queue = .{},
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
    failed: std.atomic.Value(bool) = .init(false),
    fn readLoop(self: *Child) void {
        var buffer: [16384]u8 = undefined;
        while (true) {
            var n: w.DWORD = 0;
            if (w.ReadFile(self.output, &buffer, buffer.len, &n, null) == 0 or n == 0) break;
            // Keep draining during ClosePseudoConsole, even if the UI is gone.
            _ = self.incoming.put(buffer[0..n], true);
        }
        self.incoming.done();
    }
    fn writeLoop(self: *Child) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = self.outgoing.take(&buffer);
            if (n > 0) win.writeAll(self.input, buffer[0..n]) catch {
                self.failed.store(true, .release);
                return;
            };
            w.EnterCriticalSection(&self.outgoing.lock);
            const stop = self.outgoing.stopped;
            w.LeaveCriticalSection(&self.outgoing.lock);
            if (stop) return;
            if (n == 0) _ = w.WaitForSingleObject(self.outgoing.wake, 50);
        }
    }
    fn destroy(self: *Child) void {
        self.outgoing.stop();
        self.incoming.stop();
        if (self.job != null) _ = w.TerminateJobObject(self.job, 1);
        if (self.process != null) _ = w.WaitForSingleObject(self.process, 2000);
        if (self.input != null) _ = w.CancelIoEx(self.input, null);
        if (self.pc != null) w.ClosePseudoConsole(self.pc);
        if (self.writer) |thread| thread.join();
        if (self.reader) |thread| thread.join();
        if (self.input != null) _ = w.CloseHandle(self.input);
        if (self.output != null) _ = w.CloseHandle(self.output);
        if (self.process != null) _ = w.CloseHandle(self.process);
        if (self.job != null) _ = w.CloseHandle(self.job);
        self.incoming.deinit();
        self.outgoing.deinit();
        a.destroy(self);
    }
};
pub fn milliseconds() u64 {
    return w.GetTickCount64();
}
pub fn quit() void {
    quit_requested.store(true, .release);
}
fn onControl(_: w.DWORD) callconv(.winapi) w.BOOL {
    quit();
    return 1;
}
pub fn display(bytes: []const u8) c_int {
    if (headless) return 0;
    win.writeAll(w.GetStdHandle(w.STD_OUTPUT_HANDLE), bytes) catch return -1;
    return 0;
}
pub fn write(slot: c_int, bytes: []const u8) c_int {
    if (slot < 0 or slot >= capacity) return -1;
    const child = children[@intCast(slot)] orelse return -1;
    return if (child.outgoing.put(bytes, false)) 0 else -1;
}
pub fn setSize(slot: c_int, cols: u16, rows: u16, _: u16, _: u16) c_int {
    sizes[@intCast(slot)] = .{ .X = @intCast(cols), .Y = @intCast(rows) };
    if (children[@intCast(slot)]) |child| if (w.ResizePseudoConsole(child.pc, sizes[@intCast(slot)]) < 0) return -1;
    return 0;
}
pub fn closeWindow(slot: usize) void {
    if (children[slot]) |child| {
        children[slot] = null;
        child.destroy();
    }
}
pub fn shellArgv(alloc: std.mem.Allocator, selected: ?[]const u8, command: ?[]const u8) ![]const []const u8 {
    const shell = selected orelse default_shell orelse blk: {
        if (std.c.getenv("COMPO_SHELL")) |value| break :blk std.mem.span(value);
        if (std.c.getenv("SHELL")) |value| {
            const text = std.mem.span(value);
            if (text.len > 2 and text[1] == ':') break :blk text;
        }
        const system = if (std.c.getenv("SystemRoot")) |value| std.mem.span(value) else "C:\\Windows";
        break :blk try std.fmt.allocPrint(alloc, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{system});
    };
    if (!std.fs.path.isAbsolute(shell) or std.mem.indexOfScalar(u8, shell, 0) != null) return error.InvalidShell;
    const base = std.fs.path.basename(shell);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, shell);
    if (std.ascii.eqlIgnoreCase(base, "powershell.exe") or std.ascii.eqlIgnoreCase(base, "pwsh.exe")) {
        try argv.append(alloc, "-NoLogo");
        if (command) |text| try argv.appendSlice(alloc, &.{ "-NoExit", "-Command", text });
    } else if (std.ascii.eqlIgnoreCase(base, "cmd.exe")) {
        try argv.appendSlice(alloc, &.{ "/D", "/S", "/Q" });
        if (command) |text| try argv.appendSlice(alloc, &.{ "/K", text });
    } else if (std.ascii.eqlIgnoreCase(base, "bash.exe") or std.ascii.eqlIgnoreCase(base, "sh.exe")) {
        if (command) |text| {
            try argv.appendSlice(alloc, &.{ "-c", try std.fmt.allocPrint(alloc, "{s}\nexec \"$0\" -i", .{text}), shell });
        } else try argv.append(alloc, "-i");
    } else if (command != null) return error.UnsupportedCommandShell;
    return argv.toOwnedSlice(alloc);
}
pub fn spawn(slot: usize, initial: bool) bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const key = if (initial and slot == 0 and count >= 2) "COMPO_SIDEBAR_COMMAND" else if (initial and slot == 2) "COMPO_FLOAT_COMMAND" else "COMPO_COMMAND";
    const command = if (std.c.getenv(key)) |value| std.mem.span(value) else null;
    const argv = shellArgv(arena.allocator(), null, command) catch return false;
    spawnCommand(slot, argv, null, .{}) catch |err| {
        std.log.err("Windows shell: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}
pub fn spawnCommand(slot: usize, argv: []const []const u8, cwd: ?[]const u8, env: std.json.ArrayHashMap([]const u8)) !void {
    if (children[slot] != null) return error.SlotInUse;
    const child = try a.create(Child);
    child.* = .{};
    child.incoming.init() catch |err| {
        a.destroy(child);
        return err;
    };
    child.outgoing.init() catch |err| {
        child.incoming.deinit();
        a.destroy(child);
        return err;
    };
    errdefer child.destroy();
    var input_read: w.HANDLE = null;
    var output_write: w.HANDLE = null;
    if (w.CreatePipe(&input_read, &child.input, null, 0) == 0) return error.PipeFailed;
    defer _ = w.CloseHandle(input_read);
    if (w.CreatePipe(&child.output, &output_write, null, 0) == 0) return error.PipeFailed;
    var output_open = true;
    defer if (output_open) {
        _ = w.CloseHandle(output_write);
    };
    if (w.CreatePseudoConsole(sizes[slot], input_read, output_write, 0, &child.pc) < 0) return error.PseudoConsoleFailed;
    // Drain immediately: a ConPTY call may synchronously produce output.
    child.reader = try std.Thread.spawn(.{}, Child.readLoop, .{child});
    _ = w.CloseHandle(output_write);
    output_open = false;
    var attribute_size: usize = 0;
    _ = w.InitializeProcThreadAttributeList(null, 1, 0, &attribute_size);
    const attributes = try a.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), attribute_size);
    defer a.free(attributes);
    const attribute_list: w.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attributes.ptr);
    if (w.InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_size) == 0) return error.ProcessAttributes;
    defer w.DeleteProcThreadAttributeList(attribute_list);
    if (w.UpdateProcThreadAttribute(attribute_list, 0, 0x00020016, child.pc, @sizeOf(w.HPCON), null, null) == 0) return error.ProcessAttributes;
    var si: w.STARTUPINFOEXW = std.mem.zeroes(w.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(w.STARTUPINFOEXW);
    // Prevent redirected parent stdio from overriding the pseudoconsole.
    si.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;
    si.lpAttributeList = attribute_list;
    var pi: w.PROCESS_INFORMATION = undefined;
    const line = try win.commandLine(argv);
    defer a.free(line);
    const executable = try win.wide(argv[0]);
    defer a.free(executable);
    const directory = if (cwd) |text| try win.wide(text) else null;
    defer if (directory) |text| a.free(text);
    const environment = try win.environment(env);
    defer a.free(environment);
    child.job = w.CreateJobObjectW(null, null);
    if (child.job == null) return error.JobFailed;
    var limits = std.mem.zeroes(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (w.SetInformationJobObject(child.job, w.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0) return error.JobFailed;
    if (w.CreateProcessW(executable.ptr, line.ptr, null, null, 0, w.EXTENDED_STARTUPINFO_PRESENT | w.CREATE_UNICODE_ENVIRONMENT | w.CREATE_SUSPENDED, environment.ptr, if (directory) |text| text.ptr else null, &si.StartupInfo, &pi) == 0) return error.ExecFailed;
    child.process = pi.hProcess;
    defer _ = w.CloseHandle(pi.hThread);
    if (w.AssignProcessToJobObject(child.job, child.process) == 0) {
        _ = w.TerminateProcess(child.process, 1);
        return error.JobFailed;
    }
    if (w.ResumeThread(pi.hThread) == std.math.maxInt(w.DWORD)) return error.ExecFailed;
    child.writer = try std.Thread.spawn(.{}, Child.writeLoop, .{child});
    children[slot] = child;
}
pub fn requestReload() !void {
    const script = startup_script orelse return error.NoStartupScript;
    if (startup_job) |job| if (!job.done) return error.StartupBusy;
    const job = try startup.Job.validate(script, startup_binary, &server.?.path);
    if (startup_job) |*old| old.deinit();
    startup_job = job;
    startup_phase = .validating;
    app.startupNotice("checking startup script");
}
fn geometry() !void {
    var info: w.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (!headless and w.GetConsoleScreenBufferInfo(w.GetStdHandle(w.STD_OUTPUT_HANDLE), &info) != 0) {
        root_size = .{ .X = info.srWindow.Right - info.srWindow.Left + 1, .Y = info.srWindow.Bottom - info.srWindow.Top + 1 };
    }
    if (app.compositor_resize(@intCast(root_size.X), @intCast(root_size.Y), 0, 0, @intCast(count)) != 0) return error.ResizeFailed;
}
var previous_buttons: w.DWORD = 0;
var high_surrogate: ?u16 = null;
fn consoleInput(record: w.INPUT_RECORD) !void {
    var buffer: [128]u8 = undefined;
    switch (record.EventType) {
        w.KEY_EVENT => {
            const key = record.Event.KeyEvent;
            if (key.bKeyDown == 0) return;
            var bytes: []const u8 = "";
            const ch = key.uChar.UnicodeChar;
            const alt = key.dwControlKeyState & (w.LEFT_ALT_PRESSED | w.RIGHT_ALT_PRESSED) != 0;
            const ctrl = key.dwControlKeyState & (w.LEFT_CTRL_PRESSED | w.RIGHT_CTRL_PRESSED) != 0;
            const shift = key.dwControlKeyState & w.SHIFT_PRESSED != 0;
            if (ch >= 0xd800 and ch <= 0xdbff) {
                high_surrogate = ch;
                return;
            }
            if (ch != 0) {
                var codepoint: u21 = ch;
                if (ch >= 0xdc00 and ch <= 0xdfff) {
                    if (high_surrogate) |hi| {
                        codepoint = 0x10000 + (@as(u21, hi - 0xd800) << 10) + (ch - 0xdc00);
                    } else return;
                }
                high_surrogate = null;
                const start: usize = if (alt and !ctrl) 1 else 0;
                if (start > 0) buffer[0] = 0x1b;
                const n = try std.unicode.utf8Encode(codepoint, buffer[start..][0..4]);
                bytes = buffer[0 .. start + n];
            } else {
                const final: u8 = switch (key.wVirtualKeyCode) {
                    w.VK_UP => 'A',
                    w.VK_DOWN => 'B',
                    w.VK_RIGHT => 'C',
                    w.VK_LEFT => 'D',
                    w.VK_HOME => 'H',
                    w.VK_END => 'F',
                    else => 0,
                };
                const modifier: u8 = 1 + @as(u8, if (shift) 1 else 0) + @as(u8, if (alt) 2 else 0) + @as(u8, if (ctrl) 4 else 0);
                if (final != 0) bytes = if (modifier == 1) try std.mem.print(&buffer, "\x1b[{c}", .{final}) else try std.mem.print(&buffer, "\x1b[1;{d}{c}", .{ modifier, final }) else {
                    const number: u8 = switch (key.wVirtualKeyCode) {
                        w.VK_INSERT => 2,
                        w.VK_DELETE => 3,
                        w.VK_PRIOR => 5,
                        w.VK_NEXT => 6,
                        w.VK_F1 => 11,
                        w.VK_F2 => 12,
                        w.VK_F3 => 13,
                        w.VK_F4 => 14,
                        w.VK_F5 => 15,
                        w.VK_F6 => 17,
                        w.VK_F7 => 18,
                        w.VK_F8 => 19,
                        w.VK_F9 => 20,
                        w.VK_F10 => 21,
                        w.VK_F11 => 23,
                        w.VK_F12 => 24,
                        else => return,
                    };
                    bytes = if (modifier == 1) try std.mem.print(&buffer, "\x1b[{d}~", .{number}) else try std.mem.print(&buffer, "\x1b[{d};{d}~", .{ number, modifier });
                }
            }
            for (0..key.wRepeatCount) |_| if (app.compositor_input(bytes) != 0) return error.InputFailed;
        },
        w.MOUSE_EVENT => {
            const mouse = record.Event.MouseEvent;
            const buttons = mouse.dwButtonState & 0xffff;
            const released = previous_buttons != 0 and buttons == 0;
            var button: u16 = if (buttons & 1 != 0 or released and previous_buttons & 1 != 0) 0 else if (buttons & 2 != 0 or released and previous_buttons & 2 != 0) 2 else if (buttons & 4 != 0 or released and previous_buttons & 4 != 0) 1 else 3;
            if (mouse.dwEventFlags & w.MOUSE_WHEELED != 0) {
                button = if (@as(i16, @bitCast(@as(u16, @truncate(mouse.dwButtonState >> 16)))) > 0) 64 else 65;
            }
            if (mouse.dwEventFlags & w.MOUSE_MOVED != 0) button |= 32;
            if (mouse.dwControlKeyState & w.SHIFT_PRESSED != 0) button |= 4;
            if (mouse.dwControlKeyState & (w.LEFT_ALT_PRESSED | w.RIGHT_ALT_PRESSED) != 0) button |= 8;
            if (mouse.dwControlKeyState & (w.LEFT_CTRL_PRESSED | w.RIGHT_CTRL_PRESSED) != 0) button |= 16;
            previous_buttons = buttons;
            const bytes = try std.mem.print(&buffer, "\x1b[<{d};{d};{d}{c}", .{ button, mouse.dwMousePosition.X + 1, mouse.dwMousePosition.Y + 1, if (released) @as(u8, 'm') else 'M' });
            if (app.compositor_input(bytes) != 0) return error.InputFailed;
        },
        w.WINDOW_BUFFER_SIZE_EVENT => try geometry(),
        w.FOCUS_EVENT => {
            if (app.compositor_input(if (record.Event.FocusEvent.bSetFocus != 0) "\x1b[I" else "\x1b[O") != 0) return error.InputFailed;
        },
        else => {},
    }
}
pub fn run() c_int {
    return runInner() catch |err| {
        std.log.err("Windows host: {s} (Win32 {d})", .{ @errorName(err), w.GetLastError() });
        return 1;
    };
}
fn runInner() !c_int {
    headless = std.c.getenv("COMPO_HEADLESS") != null;
    if (headless) {
        var parts = std.mem.splitScalar(u8, std.mem.span(std.c.getenv("COMPO_HEADLESS").?), 'x');
        root_size.X = try std.fmt.parseInt(i16, parts.next() orelse return error.InvalidSize, 10);
        root_size.Y = try std.fmt.parseInt(i16, parts.next() orelse return error.InvalidSize, 10);
        if (root_size.X < 3 or root_size.Y < 3 or root_size.X > 1000 or root_size.Y > 1000) return error.InvalidSize;
    }
    desktop = startup_script != null or headless or std.c.getenv("COMPO_DESKTOP") != null or (std.c.getenv("COMPO_SINGLE") == null and std.c.getenv("COMPO_FLOAT") == null and std.c.getenv("COMPO_COMMAND") == null and std.c.getenv("COMPO_SIDEBAR_COMMAND") == null and std.c.getenv("COMPO_LEGACY") == null);
    count = if (desktop) 0 else if (std.c.getenv("COMPO_SINGLE") != null) 1 else if (std.c.getenv("COMPO_FLOAT") != null) 3 else 2;
    try geometry();
    server = try control.Server.init();
    defer {
        server.?.deinit();
        server = null;
    }
    const socket_path = std.mem.sliceTo(&server.?.path, 0);
    try win.setEnv("COMPO_SOCKET", socket_path);
    try win.setEnv("COMPO_BIN", startup_binary);
    try win.setEnv("TERM", "xterm-256color");
    try win.setEnv("COLORTERM", "truecolor");
    _ = win.stderrWrite("COMPO_SOCKET=");
    _ = win.stderrWrite(socket_path);
    _ = win.stderrWrite("\n");
    defer for (0..capacity) |slot| closeWindow(slot);
    const stdin = w.GetStdHandle(w.STD_INPUT_HANDLE);
    const stdout = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
    var input_mode: w.DWORD = 0;
    var output_mode: w.DWORD = 0;
    const input_cp = w.GetConsoleCP();
    const output_cp = w.GetConsoleOutputCP();
    if (!headless and (w.GetConsoleMode(stdin, &input_mode) == 0 or w.GetConsoleMode(stdout, &output_mode) == 0)) return error.ConsoleRequired;
    if (!headless) {
        if (w.SetConsoleCP(w.CP_UTF8) == 0 or w.SetConsoleOutputCP(w.CP_UTF8) == 0) return error.ConsoleCodePage;
        if (w.SetConsoleMode(stdin, w.ENABLE_EXTENDED_FLAGS | w.ENABLE_WINDOW_INPUT | w.ENABLE_MOUSE_INPUT) == 0 or w.SetConsoleMode(stdout, output_mode | w.ENABLE_VIRTUAL_TERMINAL_PROCESSING | w.DISABLE_NEWLINE_AUTO_RETURN) == 0) return error.ConsoleMode;
    }
    defer if (!headless) {
        _ = w.SetConsoleCP(input_cp);
        _ = w.SetConsoleOutputCP(output_cp);
        _ = w.SetConsoleMode(stdin, input_mode);
        _ = w.SetConsoleMode(stdout, output_mode);
    };
    _ = w.SetConsoleCtrlHandler(onControl, 1);
    defer _ = w.SetConsoleCtrlHandler(onControl, 0);
    defer {
        app.compositor_finish();
        _ = display("\x1b[?2026l\x1b[0m\x1b[?1l\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[0 q\x1b[?1049l");
    }
    if (display("\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[2J") != 0) return error.DisplayFailed;
    for (0..count) |slot| if (!spawn(slot, true)) return error.SpawnFailed;
    if (startup_script) |script| {
        startup_job = try startup.Job.start(script, startup_binary, &server.?.path);
    } else startup_phase = .idle;
    defer if (startup_job) |*job| job.deinit();
    var dirty = true;
    var input_time: ?u64 = null;
    while (!quit_requested.load(.acquire)) {
        if (startup_job) |*job| if (job.check()) |status| {
            if (startup_phase == .initial) {
                if (status != 0) return status;
                startup_phase = .idle;
            } else if (startup_phase == .validating and status == 0) {
                app.closeAllWindows();
                app.replayTitle();
                startup_job = startup.Job.start(startup_script.?, startup_binary, &server.?.path) catch {
                    startup_phase = .idle;
                    app.startupNotice("reload failed");
                    continue;
                };
                startup_phase = .reloading;
            } else {
                startup_phase = .idle;
                app.startupNotice(if (status == 0) "reloaded" else "reload failed");
            }
            dirty = true;
        };
        if (app.compositor_tick(milliseconds())) dirty = true;
        var fds: [control.poll_count]net.pollfd = undefined;
        server.?.pollfds(&fds);
        _ = net.poll(&fds, fds.len, 0);
        server.?.service(&fds, @intCast(root_size.X), @intCast(root_size.Y));
        if (app.control_dirty) {
            dirty = true;
            app.control_dirty = false;
        }
        var buffer: [16384]u8 = undefined;
        var alive = false;
        for (&children, 0..) |maybe, slot| if (maybe) |child| {
            alive = true;
            const n = child.incoming.take(&buffer);
            if (n > 0) {
                if (app.compositor_output(@intCast(slot), buffer[0..n]) != 0) return error.TerminalOutput;
                dirty = true;
            }
            // ConPTY can keep its output pipe open after the shell exits.
            if (w.WaitForSingleObject(child.process, 0) == w.WAIT_OBJECT_0 or child.incoming.drained() or child.failed.load(.acquire)) {
                var status: w.DWORD = 0;
                _ = w.GetExitCodeProcess(child.process, &status);
                if (!desktop and slot == (if (count == 1) @as(usize, 0) else 1)) main_status = @intCast(@min(status, 255));
                closeWindow(slot);
                if (app.compositor_exit(@intCast(slot)) != 0) return error.TerminalExit;
                dirty = true;
            }
        };
        if (!desktop and !alive) break;
        if (!headless) {
            var pending: w.DWORD = 0;
            if (w.GetNumberOfConsoleInputEvents(stdin, &pending) == 0) return error.ConsoleRead;
            if (pending > 0) {
                var records: [64]w.INPUT_RECORD = undefined;
                var read: w.DWORD = 0;
                if (w.ReadConsoleInputW(stdin, &records, @intCast(@min(pending, records.len)), &read) == 0) return error.ConsoleRead;
                for (records[0..read]) |record| try consoleInput(record);
                input_time = milliseconds();
                dirty = true;
            } else if (input_time) |time| if (milliseconds() -| time >= 50) {
                if (app.compositor_idle() != 0) return error.InputFailed;
                input_time = null;
                dirty = true;
            };
        }
        if (dirty) {
            if (app.compositor_draw() != 0) return error.DrawFailed;
            dirty = false;
        }
        w.Sleep(5);
    }
    return main_status;
}
