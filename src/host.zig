//! POSIX PTY and tty adapter. Layout and terminal emulation live in shell.zig.
const std = @import("std");
const c = std.c;
const app = @import("root");
// Darwin sys/ttycom.h: _IOW('t', 103, struct winsize).
// std.c currently exposes only TIOCGWINSZ on Darwin.
const set_winsize: u32 = if (@import("builtin").target.os.tag == .macos)
    0x80000000 | (@sizeOf(c.winsize) << 16) | ('t' << 8) | 103
else
    c.T.IOCSWINSZ;

extern "c" fn forkpty(*c.fd_t, ?[*]u8, ?*const c.termios, ?*const c.winsize) c.pid_t;
extern "c" fn cfmakeraw(*c.termios) void;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn execv([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

var masters: [3]c.fd_t = .{ -1, -1, -1 };
var sizes: [3]c.winsize = @splat(std.mem.zeroes(c.winsize));
var count: usize = 2;
var resized: c_int = 0;
var stopped: c_int = 0;
fn signalValue(value: *c_int) *volatile c_int {
    return value;
}
fn onSignal(sig: c.SIG) callconv(.c) void {
    if (sig == .WINCH) signalValue(&resized).* = 1 else signalValue(&stopped).* = @intCast(@backingInt(sig));
}
fn milliseconds() u64 {
    var now: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}
fn writeAll(fd: c.fd_t, bytes: []const u8) c_int {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and c.errno(n) == .INTR and signalValue(&stopped).* == 0) continue;
        if (n <= 0) return -1;
        offset += @intCast(n);
    }
    return 0;
}
pub fn write(slot: c_int, bytes: []const u8) c_int {
    if (slot < 0 or slot >= count or masters[@intCast(slot)] < 0) return -1;
    return writeAll(masters[@intCast(slot)], bytes);
}
pub fn setSize(slot: c_int, cols: u16, rows: u16, cw: u16, ch: u16) c_int {
    const index: usize = @intCast(slot);
    sizes[index] = .{ .col = cols, .row = rows, .xpixel = cols *| cw, .ypixel = rows *| ch };
    return if (masters[index] < 0) 0 else c.ioctl(masters[index], @as(c_int, @bitCast(set_winsize)), &sizes[index]);
}
pub fn display(bytes: []const u8) c_int {
    return writeAll(1, bytes);
}
fn geometry(ws: *c.winsize) c_int {
    if (c.ioctl(0, @as(c_int, @bitCast(@as(u32, c.T.IOCGWINSZ))), ws) < 0) return -1;
    if (ws.col == 0 or ws.row == 0) return 0;
    return app.compositor_resize(ws.col, ws.row, ws.xpixel / ws.col, ws.ypixel / ws.row, @intCast(count));
}
fn reap(pid: c.pid_t, status: *c_int, options: c_int) c.pid_t {
    while (true) {
        const result = c.waitpid(pid, status, options);
        if (result < 0 and c.errno(result) == .INTR) continue;
        return result;
    }
}
fn cleanupChildren(children: []const c.pid_t, statuses: []c_int) void {
    // Only process groups created by this host's forkpty calls.
    for (children, statuses, 0..) |pid, *status, slot| {
        if (masters[slot] >= 0) _ = c.close(masters[slot]);
        masters[slot] = -1;
        if (reap(pid, status, c.W.NOHANG) != 0) continue;
        _ = c.kill(-pid, .HUP);
        var reaped = false;
        for (0..20) |_| {
            if (reap(pid, status, c.W.NOHANG) != 0) {
                reaped = true;
                break;
            }
            const delay: c.timespec = .{ .sec = 0, .nsec = 10_000_000 };
            _ = c.nanosleep(&delay, null);
        }
        if (!reaped) {
            _ = c.kill(-pid, .KILL);
            _ = reap(pid, status, 0);
        }
    }
}
fn loop(ws: *c.winsize) c_int {
    var dirty = true;
    var alive = count;
    var input_time: ?u64 = null;
    while (signalValue(&stopped).* == 0 and alive != 0) {
        if (input_time) |time| if (milliseconds() -| time >= 50) {
            if (app.compositor_idle() != 0) return 1;
            input_time = null;
        };
        if (signalValue(&resized).* != 0) {
            signalValue(&resized).* = 0;
            if (geometry(ws) != 0) return 1;
            dirty = true;
        }
        if (dirty) {
            if (app.compositor_draw() != 0) return 1;
            dirty = false;
        }
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = masters[0], .events = c.POLL.IN, .revents = 0 },
            .{ .fd = masters[1], .events = c.POLL.IN, .revents = 0 },
            .{ .fd = masters[2], .events = c.POLL.IN, .revents = 0 },
        };
        const ready = c.poll(&fds, fds.len, 50);
        if (ready < 0) {
            if (c.errno(ready) == .INTR) continue;
            return 1;
        }
        var bytes: [16384]u8 = undefined;
        for (0..count) |slot| {
            if (masters[slot] < 0 or fds[slot + 1].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
            const n = c.read(masters[slot], &bytes, bytes.len);
            if (n > 0) {
                if (app.compositor_output(@intCast(slot), bytes[0..@intCast(n)]) != 0) return 1;
                dirty = true;
            } else if (n == 0 or c.errno(n) == .IO) {
                _ = c.close(masters[slot]);
                masters[slot] = -1;
                alive -= 1;
                if (app.compositor_exit(@intCast(slot)) != 0) return 1;
                dirty = true;
            } else if (c.errno(n) != .INTR) return 1;
        }
        if (fds[0].revents & c.POLL.IN != 0) {
            const n = c.read(0, &bytes, bytes.len);
            if (n == 0) break;
            if (n < 0) {
                if (c.errno(n) == .INTR) continue;
                return 1;
            }
            if (app.compositor_input(bytes[0..@intCast(n)]) != 0) return 1;
            input_time = milliseconds();
            dirty = true;
        }
        if (fds[0].revents & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL) != 0) break;
    }
    return 0;
}
pub fn run() c_int {
    var original: c.termios = undefined;
    var ws: c.winsize = std.mem.zeroes(c.winsize);
    if (c.isatty(0) == 0 or c.isatty(1) == 0 or c.tcgetattr(0, &original) < 0) {
        _ = writeAll(2, "tmuxpp-shell needs a terminal on stdin and stdout\n");
        return 1;
    }
    count = if (c.getenv("TMUXPP_SINGLE") != null) 1 else if (c.getenv("TMUXPP_FLOAT") != null) 3 else 2;
    if (geometry(&ws) < 0 or ws.col == 0 or ws.row == 0) return 1;
    const env_shell = c.getenv("SHELL");
    const shell: [*:0]const u8 = if (env_shell != null and env_shell.?[0] == '/') env_shell.? else "/bin/sh";
    var children: [3]c.pid_t = .{ -1, -1, -1 };
    var statuses: [3]c_int = .{ 0, 0, 0 };
    var spawned: usize = 0;
    defer cleanupChildren(children[0..spawned], statuses[0..spawned]);
    for (0..count) |slot| {
        const command = c.getenv(if (slot == 0 and count >= 2) "TMUXPP_SIDEBAR_COMMAND" else if (slot == 2) "TMUXPP_FLOAT_COMMAND" else "TMUXPP_COMMAND");
        const child = forkpty(&masters[slot], null, &original, &sizes[slot]);
        if (child < 0) {
            _ = writeAll(2, "forkpty failed\n");
            return 1;
        }
        if (child == 0) {
            for (masters[0..slot]) |fd| _ = c.close(fd);
            if (setenv("TERM", "xterm-256color", 1) != 0 or setenv("COLORTERM", "truecolor", 1) != 0) c._exit(127);
            if (command) |cmd| {
                const argv = [_:null]?[*:0]const u8{ shell, "-c", cmd };
                _ = execv(shell, &argv);
            } else {
                const argv = [_:null]?[*:0]const u8{ shell, "-i" };
                _ = execv(shell, &argv);
            }
            _ = writeAll(2, "exec shell failed\n");
            c._exit(127);
        }
        children[slot] = child;
        spawned += 1;
    }
    const signals = [_]c.SIG{ .WINCH, .TERM, .HUP, .INT, .PIPE };
    var saved: [signals.len]c.Sigaction = undefined;
    var action = std.mem.zeroes(c.Sigaction);
    action.handler.handler = onSignal;
    _ = c.sigemptyset(&action.mask);
    var installed: usize = 0;
    defer for (signals[0..installed], saved[0..installed]) |sig, *old| {
        _ = c.sigaction(sig, old, null);
    };
    for (signals, &saved) |sig, *old| {
        if (c.sigaction(sig, &action, old) != 0) return 1;
        installed += 1;
    }
    var raw = original;
    cfmakeraw(&raw);
    if (c.tcsetattr(0, .NOW, &raw) < 0) return 1;
    defer {
        _ = c.tcsetattr(0, .NOW, &original);
    }
    defer {
        app.compositor_finish();
        _ = writeAll(1, "\x1b[?2026l\x1b[0m\x1b[?1l\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[?1049l");
    }
    if (writeAll(1, "\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[2J") != 0) return 1;
    const result = loop(&ws);
    cleanupChildren(children[0..spawned], statuses[0..spawned]);
    spawned = 0;
    if (signalValue(&stopped).* != 0) return 128 + signalValue(&stopped).*;
    if (result != 0) return result;
    const status: u32 = @bitCast(statuses[if (count == 1) 0 else 1]);
    return if (c.W.IFEXITED(status)) c.W.EXITSTATUS(status) else 128 + @as(c_int, @intCast(@backingInt(c.W.TERMSIG(status))));
}
