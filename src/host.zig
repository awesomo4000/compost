//! POSIX PTY and tty adapter. Layout and terminal emulation live in shell.zig.
const std = @import("std");
const c = std.c;
const app = @import("root");
const control = @import("control.zig");
var control_server: ?control.Server = null;
pub var startup_script: ?[:0]const u8 = null;
pub var startup_binary: [:0]const u8 = "";
var startup_job: ?@import("startup.zig").Job = null;
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

pub const capacity = 32;
pub var desktop = false;
var headless = false;
var quit_requested = false;
var original: c.termios = undefined;
var children: [capacity]c.pid_t = @splat(-1);
var statuses: [capacity]c_int = @splat(0);
var main_status: ?c_int = null;
var masters: [capacity]c.fd_t = @splat(-1);
var sizes: [capacity]c.winsize = @splat(std.mem.zeroes(c.winsize));
var count: usize = 2;
var resized: c_int = 0;
var stopped: c_int = 0;
fn signalValue(value: *c_int) *volatile c_int {
    return value;
}
fn onSignal(sig: c.SIG) callconv(.c) void {
    if (sig == .WINCH) signalValue(&resized).* = 1 else signalValue(&stopped).* = @intCast(@backingInt(sig));
}
pub fn milliseconds() u64 {
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
    if (slot < 0 or slot >= capacity or masters[@intCast(slot)] < 0) return -1;
    return writeAll(masters[@intCast(slot)], bytes);
}
pub fn setSize(slot: c_int, cols: u16, rows: u16, cw: u16, ch: u16) c_int {
    const index: usize = @intCast(slot);
    sizes[index] = .{ .col = cols, .row = rows, .xpixel = cols *| cw, .ypixel = rows *| ch };
    return if (masters[index] < 0) 0 else c.ioctl(masters[index], @as(c_int, @bitCast(set_winsize)), &sizes[index]);
}
pub fn display(bytes: []const u8) c_int {
    return if (headless) 0 else writeAll(1, bytes);
}
fn geometry(ws: *c.winsize) c_int {
    if (headless) return app.compositor_resize(ws.col, ws.row, 8, 16, 0);
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
pub fn quit() void {
    quit_requested = true;
}
fn cleanupSlot(slot: usize) void {
    const pid = children[slot];
    if (pid < 0) return;
    if (masters[slot] >= 0) _ = c.close(masters[slot]);
    masters[slot] = -1;
    if (reap(pid, &statuses[slot], c.W.NOHANG) == 0) {
        _ = c.kill(-pid, .HUP);
        var reaped = false;
        for (0..20) |_| {
            if (reap(pid, &statuses[slot], c.W.NOHANG) != 0) {
                reaped = true;
                break;
            }
            const delay: c.timespec = .{ .sec = 0, .nsec = 10_000_000 };
            _ = c.nanosleep(&delay, null);
        }
        if (!reaped) {
            _ = c.kill(-pid, .KILL);
            _ = reap(pid, &statuses[slot], 0);
        }
    }
    children[slot] = -1;
    if (!desktop and main_status == null and slot == (if (count == 1) @as(usize, 0) else 1)) main_status = statuses[slot];
}
fn cleanupChildren() void {
    for (0..capacity) |slot| cleanupSlot(slot);
}
fn anyAlive() bool {
    for (masters) |fd| if (fd >= 0) return true;
    return false;
}
pub fn spawn(slot: usize, initial: bool) bool {
    if (children[slot] >= 0) return false;
    const env_shell = c.getenv("SHELL");
    const shell: [*:0]const u8 = if (env_shell != null and env_shell.?[0] == '/') env_shell.? else "/bin/sh";
    const command = c.getenv(if (initial and slot == 0 and count >= 2) "COMPO_SIDEBAR_COMMAND" else if (initial and slot == 2) "COMPO_FLOAT_COMMAND" else "COMPO_COMMAND");
    const child = forkpty(&masters[slot], null, if (headless) null else &original, &sizes[slot]);
    if (child < 0) {
        masters[slot] = -1;
        return false;
    }
    if (child == 0) {
        for (masters, 0..) |fd, i| if (i != slot and fd >= 0) {
            _ = c.close(fd);
        };
        if (control_server) |*server| {
            if (setenv("COMPO_SOCKET", &server.path, 1) != 0) c._exit(127);
        }
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
    statuses[slot] = 0;
    return true;
}
fn loop(ws: *c.winsize) c_int {
    var dirty = true;
    var input_time: ?u64 = null;
    while (signalValue(&stopped).* == 0 and !quit_requested and (desktop or anyAlive())) {
        if (startup_job) |*job| if (job.check()) |status| {
            if (status != 0) return status;
        };
        if (app.compositor_tick(milliseconds())) dirty = true;
        if (signalValue(&resized).* != 0) {
            signalValue(&resized).* = 0;
            if (geometry(ws) != 0) return 1;
            dirty = true;
        }
        if (dirty) {
            if (app.compositor_draw() != 0) return 1;
            dirty = false;
        }
        var fds: [capacity + 1 + control.poll_count]c.pollfd = undefined;
        fds[0] = .{ .fd = if (headless) -1 else 0, .events = c.POLL.IN, .revents = 0 };
        for (masters, 0..) |fd, index| fds[index + 1] = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        control_server.?.pollfds(fds[capacity + 1 ..]);
        const ready = c.poll(&fds, fds.len, 50);
        if (ready < 0) {
            if (c.errno(ready) == .INTR) continue;
            return 1;
        }
        // Check readiness before timing out Escape. A busy renderer must not
        // flush a partial key when its continuation is already waiting on stdin.
        if (fds[0].revents & c.POLL.IN == 0) {
            if (input_time) |time| if (milliseconds() -| time >= 50) {
                if (app.compositor_idle() != 0) return 1;
                input_time = null;
                dirty = true;
            };
        }
        const polled_children = children;
        control_server.?.service(fds[capacity + 1 ..], ws.col, ws.row);
        if (app.control_dirty) {
            dirty = true;
            app.control_dirty = false;
        }
        var bytes: [16384]u8 = undefined;
        for (0..capacity) |slot| {
            // Control may reuse a slot and even its fd. Match the child identity
            // too, while still servicing unaffected PTYs during control traffic.
            if (polled_children[slot] != children[slot] or fds[slot + 1].fd != masters[slot]) continue;
            if (masters[slot] < 0 or fds[slot + 1].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
            const n = c.read(masters[slot], &bytes, bytes.len);
            if (n > 0) {
                if (app.compositor_output(@intCast(slot), bytes[0..@intCast(n)]) != 0) return 1;
                dirty = true;
            } else if (n == 0 or c.errno(n) == .IO) {
                _ = c.close(masters[slot]);
                masters[slot] = -1;
                cleanupSlot(slot);
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
    var ws: c.winsize = std.mem.zeroes(c.winsize);
    headless = c.getenv("COMPO_HEADLESS") != null;
    if (headless) {
        const dimensions = std.mem.span(c.getenv("COMPO_HEADLESS").?);
        const split = std.mem.indexOfScalar(u8, dimensions, 'x') orelse return 1;
        ws.col = std.fmt.parseInt(u16, dimensions[0..split], 10) catch return 1;
        ws.row = std.fmt.parseInt(u16, dimensions[split + 1 ..], 10) catch return 1;
        if (ws.col < 3 or ws.row < 3 or ws.col > 1000 or ws.row > 1000) return 1;
    }
    if (!headless and (c.isatty(0) == 0 or c.isatty(1) == 0 or c.tcgetattr(0, &original) < 0)) {
        _ = writeAll(2, "compo needs a terminal on stdin and stdout\n");
        return 1;
    }
    desktop = startup_script != null or headless or c.getenv("COMPO_DESKTOP") != null or
        (c.getenv("COMPO_SINGLE") == null and c.getenv("COMPO_FLOAT") == null and
            c.getenv("COMPO_COMMAND") == null and c.getenv("COMPO_SIDEBAR_COMMAND") == null and c.getenv("COMPO_LEGACY") == null);
    count = if (desktop) 0 else if (c.getenv("COMPO_SINGLE") != null) 1 else if (c.getenv("COMPO_FLOAT") != null) 3 else 2;
    if (geometry(&ws) < 0 or ws.col == 0 or ws.row == 0) return 1;
    control_server = control.Server.init() catch {
        _ = writeAll(2, "Unable to create compo control socket\n");
        return 1;
    };
    defer {
        control_server.?.deinit();
        control_server = null;
    }
    _ = writeAll(2, "COMPO_SOCKET=");
    _ = writeAll(2, std.mem.sliceTo(&control_server.?.path, 0));
    _ = writeAll(2, "\n");
    defer cleanupChildren();
    for (0..count) |slot| if (!spawn(slot, true)) return 1;
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
    if (!headless) {
        var raw = original;
        cfmakeraw(&raw);
        if (c.tcsetattr(0, .NOW, &raw) < 0) return 1;
    }
    defer {
        if (!headless) _ = c.tcsetattr(0, .NOW, &original);
    }
    defer {
        app.compositor_finish();
        _ = display("\x1b[?2026l\x1b[0m\x1b[?1l\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[0 q\x1b[?1049l");
    }
    if (display("\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[2J") != 0) return 1;
    if (startup_script) |script| {
        startup_job = @import("startup.zig").Job.start(script, startup_binary, &control_server.?.path) catch |err| {
            std.log.err("could not start startup script: {s}", .{@errorName(err)});
            return 1;
        };
    }
    defer if (startup_job) |*job| job.deinit();
    const result = loop(&ws);
    cleanupChildren();
    if (signalValue(&stopped).* != 0) return 128 + signalValue(&stopped).*;
    if (result != 0) return result;
    const status: u32 = @bitCast(main_status orelse 0);
    return if (c.W.IFEXITED(status)) c.W.EXITSTATUS(status) else 128 + @as(c_int, @intCast(@backingInt(c.W.TERMSIG(status))));
}

pub fn closeWindow(slot: usize) void {
    cleanupSlot(slot);
}

/// The CLOEXEC status pipe distinguishes successful exec from child setup failure.
/// All strings and pointer arrays are prepared before fork.
pub fn spawnCommand(slot: usize, argv: []const []const u8, cwd: ?[]const u8, env: std.json.ArrayHashMap([]const u8)) !void {
    const a = std.heap.smp_allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const args = try temp.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args[i] = try temp.dupeSentinel(u8, arg, 0);
    const directory = if (cwd) |path| try temp.dupeSentinel(u8, path, 0) else null;
    const Pair = struct { key: [:0]u8, value: [:0]u8 };
    const pairs = try temp.alloc(Pair, env.map.count());
    for (env.map.keys(), env.map.values(), pairs) |key, value, *pair| pair.* = .{ .key = try temp.dupeSentinel(u8, key, 0), .value = try temp.dupeSentinel(u8, value, 0) };
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.SpawnFailed;
    defer _ = c.close(pipe[0]);
    var writer_open = true;
    defer if (writer_open) {
        _ = c.close(pipe[1]);
    };
    if (c.fcntl(pipe[1], c.F.SETFD, @as(c_int, 1)) < 0) return error.SpawnFailed;
    const pid = forkpty(&masters[slot], null, if (headless) null else &original, &sizes[slot]);
    if (pid < 0) {
        masters[slot] = -1;
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = c.close(pipe[0]);
        for (masters, 0..) |fd, i| if (i != slot and fd >= 0) {
            _ = c.close(fd);
        };
        var valid = true;
        if (directory) |path| valid = c.chdir(path) == 0;
        if (setenv("TERM", "xterm-256color", 1) != 0 or setenv("COLORTERM", "truecolor", 1) != 0) valid = false;
        for (pairs) |pair| if (setenv(pair.key, pair.value, 1) != 0) {
            valid = false;
        };
        if (control_server) |*server| if (setenv("COMPO_SOCKET", &server.path, 1) != 0) {
            valid = false;
        };
        if (valid) _ = execv(args[0].?, args.ptr);
        _ = c.write(pipe[1], "!", 1);
        c._exit(127);
    }
    children[slot] = pid;
    statuses[slot] = 0;
    _ = c.close(pipe[1]);
    writer_open = false;
    var fd = [_]c.pollfd{.{ .fd = pipe[0], .events = c.POLL.IN, .revents = 0 }};
    const ready = c.poll(&fd, 1, 1000);
    var byte: [1]u8 = undefined;
    if (ready <= 0 or c.read(pipe[0], &byte, 1) != 0) {
        cleanupSlot(slot);
        return error.ExecFailed;
    }
}
