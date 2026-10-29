//! Startup scripts use the live socket while the host keeps servicing events.
const std = @import("std");
const c = std.c;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn execv([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

pub fn findScript(a: std.mem.Allocator, explicit: ?[:0]const u8, disabled: bool) !?[:0]const u8 {
    if (disabled) return null;
    var path = explicit;
    var required = path != null;
    if (path == null) if (c.getenv("COMPO_INIT")) |v| {
        path = std.mem.span(v);
        required = true;
    };
    if (path == null) {
        // Headless tests do not implicitly load a user's desktop configuration.
        if (c.getenv("COMPO_HEADLESS") != null) return null;
        const base = base: {
            if (c.getenv("XDG_CONFIG_HOME")) |v| {
                const value = std.mem.span(v);
                if (value.len > 0 and value[0] == '/') break :base value;
            }
            const home = if (c.getenv("HOME")) |v| std.mem.span(v) else return null;
            if (home.len == 0 or home[0] != '/') return null;
            break :base try std.fmt.allocPrint(a, "{s}/.config", .{home});
        };
        path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/compo/init.sh", .{base}), 0);
    }
    if (path.?.len == 0) return error.MissingStartupFile;
    const result = c.access(path.?.ptr, 4); // POSIX R_OK
    if (result != 0) {
        if (!required and c.errno(result) == .NOENT) return null;
        return error.StartupFileUnreadable;
    }
    if (std.fs.path.isAbsolute(path.?)) return path;
    var cwd: [4096]u8 = undefined;
    const base = c.getcwd(&cwd, cwd.len) orelse return error.StartupDirectoryUnavailable;
    return try a.dupeSentinel(u8, try std.fs.path.join(a, &.{ std.mem.span(@as([*:0]const u8, @ptrCast(base))), path.? }), 0);
}

pub const Job = struct {
    pid: c.pid_t,
    fd: c.fd_t,
    done: bool = false,
    output: [16384]u8 = undefined,
    used: usize = 0,
    truncated: bool = false,

    pub fn start(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8) !Job {
        return launch(script, binary, socket, false);
    }

    pub fn validate(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8) !Job {
        if (c.access(script.ptr, 4) != 0) return error.StartupFileUnreadable;
        return launch(script, binary, socket, true);
    }

    fn launch(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8, syntax_only: bool) !Job {
        var pipe: [2]c.fd_t = undefined;
        if (c.pipe(&pipe) != 0) return error.StartupPipeFailed;
        errdefer _ = c.close(pipe[0]);
        defer _ = c.close(pipe[1]);
        const flags = c.fcntl(pipe[0], c.F.GETFL);
        const nonblock: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
        if (flags < 0 or c.fcntl(pipe[0], c.F.SETFL, flags | nonblock) < 0 or
            c.fcntl(pipe[0], c.F.SETFD, @as(c_int, 1)) < 0 or
            c.fcntl(pipe[1], c.F.SETFD, @as(c_int, 1)) < 0) return error.StartupPipeFailed;
        const input = c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        if (input < 0) return error.StartupInputFailed;
        defer _ = c.close(input);
        const pid = c.fork();
        if (pid < 0) return error.StartupForkFailed;
        if (pid == 0) {
            _ = c.setpgid(0, 0);
            // The host has installed signal handlers; restore defaults before exec.
            var action = std.mem.zeroes(c.Sigaction);
            action.handler.handler = c.SIG.DFL;
            _ = c.sigemptyset(&action.mask);
            for ([_]c.SIG{ .WINCH, .TERM, .HUP, .INT, .PIPE }) |sig| _ = c.sigaction(sig, &action, null);
            if (c.dup2(input, 0) < 0 or c.dup2(pipe[1], 1) < 0 or c.dup2(pipe[1], 2) < 0) c._exit(127);
            _ = c.close(input);
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            if (setenv("COMPO_SOCKET", socket, 1) != 0 or setenv("COMPO_BIN", binary.ptr, 1) != 0) c._exit(127);
            // Pass the path as an argument, never interpolate it into shell text.
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "--", script.ptr };
            const check_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-n", "--", script.ptr };
            _ = execv("/bin/sh", if (syntax_only) &check_argv else &argv);
            c._exit(127);
        }
        _ = c.setpgid(pid, pid);
        return .{ .pid = pid, .fd = pipe[0] };
    }

    pub fn check(self: *Job) ?u8 {
        if (self.done) return null;
        var bytes: [4096]u8 = undefined;
        // Bound work per tick while continuing to drain even after storage fills.
        for (0..4) |_| {
            const n = c.read(self.fd, &bytes, bytes.len);
            if (n <= 0) break;
            const size: usize = @intCast(n);
            const keep = @min(size, self.output.len - self.used);
            @memcpy(self.output[self.used..][0..keep], bytes[0..keep]);
            self.used += keep;
            if (keep != size) self.truncated = true;
        }
        var status: c_int = 0;
        if (c.waitpid(self.pid, &status, c.W.NOHANG) != self.pid) return null;
        self.pid = -1;
        self.done = true;
        _ = c.close(self.fd);
        self.fd = -1;
        const bits: u32 = @bitCast(status);
        const code: u8 = if (c.W.IFEXITED(bits)) @intCast(c.W.EXITSTATUS(bits)) else @intCast(128 + @as(u32, @intCast(@backingInt(c.W.TERMSIG(bits)))));
        if (code != 0) {
            std.log.err("startup script exited with status {d}\n{s}{s}", .{ code, self.output[0..self.used], if (self.truncated) "\n[additional startup output omitted]" else "" });
        }
        return code;
    }

    pub fn deinit(self: *Job) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        if (self.pid < 0) return;
        _ = c.kill(-self.pid, .TERM);
        var status: c_int = 0;
        for (0..20) |_| {
            if (c.waitpid(self.pid, &status, c.W.NOHANG) == self.pid) return;
            const delay: c.timespec = .{ .sec = 0, .nsec = 10_000_000 };
            _ = c.nanosleep(&delay, null);
        }
        _ = c.kill(-self.pid, .KILL);
        while (c.waitpid(self.pid, &status, 0) < 0 and c.errno(-1) == .INTR) {}
    }
};
