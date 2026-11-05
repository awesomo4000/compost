//! Native startup jobs: PowerShell scripts, or Git Bash scripts when requested.
const std = @import("std");
const win = @import("win.zig");
const w = win.c;
pub fn findScript(a: std.mem.Allocator, explicit: ?[:0]const u8, disabled: bool) !?[:0]const u8 {
    if (disabled) return null;
    var path = explicit;
    var required = path != null;
    if (path == null) if (std.c.getenv("COMPO_INIT")) |value| {
        path = std.mem.span(value);
        required = true;
    };
    if (path == null) {
        if (std.c.getenv("COMPO_HEADLESS") != null) return null;
        const home = if (std.c.getenv("USERPROFILE")) |value| std.mem.span(value) else return null;
        path = try a.dupeSentinel(u8, try std.fs.path.join(a, &.{ home, ".config", "compo", "init.ps1" }), 0);
    }
    if (path.?.len == 0) return error.MissingStartupFile;
    const native = try win.wide(path.?);
    defer win.a.free(native);
    const attrs = w.GetFileAttributesW(native.ptr);
    if (attrs == w.INVALID_FILE_ATTRIBUTES) {
        if (!required and w.GetLastError() == w.ERROR_FILE_NOT_FOUND) return null;
        if (!required and w.GetLastError() == w.ERROR_PATH_NOT_FOUND) return null;
        return error.StartupFileUnreadable;
    }
    if (attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0) return error.StartupFileUnreadable;
    if (std.fs.path.isAbsolute(path.?)) return path;
    var buffer: [32768]u8 = undefined;
    const base = win.cwd(&buffer) orelse return error.StartupDirectoryUnavailable;
    return try a.dupeSentinel(u8, try std.fs.path.join(a, &.{ std.mem.sliceTo(base, 0), path.? }), 0);
}
pub const Job = struct {
    process: w.HANDLE,
    job: w.HANDLE,
    pipe: w.HANDLE,
    done: bool = false,
    output: [16384]u8 = undefined,
    used: usize = 0,
    pub fn start(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8) !Job {
        return launch(script, binary, socket, false);
    }
    pub fn validate(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8) !Job {
        return launch(script, binary, socket, true);
    }
    fn launch(script: [:0]const u8, binary: [:0]const u8, socket: [*:0]const u8, syntax_only: bool) !Job {
        var arena = std.heap.ArenaAllocator.init(win.a);
        defer arena.deinit();
        const a = arena.allocator();
        const system = if (std.c.getenv("SystemRoot")) |value| std.mem.span(value) else "C:\\Windows";
        const powershell = try std.fmt.allocPrint(a, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{system});
        var argv: []const []const u8 = undefined;
        if (std.ascii.endsWithIgnoreCase(script, ".sh")) {
            const git_bash = if (std.c.getenv("COMPO_BASH")) |value| std.mem.span(value) else "C:\\Program Files\\Git\\bin\\bash.exe";
            // Git Bash accepts forward-slash drive paths in script arguments.
            const shell_path = try a.dupe(u8, script);
            std.mem.replaceScalar(u8, shell_path, '\\', '/');
            argv = if (syntax_only) &.{ git_bash, "-n", "--", shell_path } else &.{ git_bash, "--", shell_path };
        } else if (std.ascii.endsWithIgnoreCase(script, ".ps1")) {
            if (syntax_only) {
                // The path is passed as data in an environment variable, not interpolated.
                argv = &.{ powershell, "-NoProfile", "-NonInteractive", "-Command", "$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:COMPO_CHECK_SCRIPT,[ref]$tokens,[ref]$errors); if ($errors.Count) { $errors | Out-String | Write-Error; exit 1 }" };
            } else argv = &.{ powershell, "-NoProfile", "-NonInteractive", "-File", script };
        } else return error.UnsupportedStartupScript;
        var env: std.json.ArrayHashMap([]const u8) = .{};
        try env.map.put(a, "COMPO_BIN", binary);
        try env.map.put(a, "COMPO_SOCKET", std.mem.span(socket));
        try env.map.put(a, "COMPO_CHECK_SCRIPT", script);
        const environment = try win.environment(env);
        defer win.a.free(environment);
        const line = try win.commandLine(argv);
        defer win.a.free(line);
        const executable = try win.wide(argv[0]);
        defer win.a.free(executable);
        var sa: w.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
        var reader: w.HANDLE = null;
        var writer: w.HANDLE = null;
        if (w.CreatePipe(&reader, &writer, &sa, 0) == 0) return error.StartupPipeFailed;
        errdefer _ = w.CloseHandle(reader);
        defer _ = w.CloseHandle(writer);
        if (w.SetHandleInformation(reader, w.HANDLE_FLAG_INHERIT, 0) == 0) return error.StartupPipeFailed;
        const nul = w.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, &sa, w.OPEN_EXISTING, 0, null);
        if (nul == w.INVALID_HANDLE_VALUE) return error.StartupInputFailed;
        defer _ = w.CloseHandle(nul);
        const job = w.CreateJobObjectW(null, null);
        if (job == null) return error.JobFailed;
        errdefer _ = w.CloseHandle(job);
        var limits = std.mem.zeroes(w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (w.SetInformationJobObject(job, w.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0) return error.JobFailed;
        var si = std.mem.zeroes(w.STARTUPINFOW);
        si.cb = @sizeOf(w.STARTUPINFOW);
        si.dwFlags = w.STARTF_USESTDHANDLES;
        si.hStdInput = nul;
        si.hStdOutput = writer;
        si.hStdError = writer;
        var pi: w.PROCESS_INFORMATION = undefined;
        if (w.CreateProcessW(executable.ptr, line.ptr, null, null, 1, w.CREATE_UNICODE_ENVIRONMENT | w.CREATE_NO_WINDOW | w.CREATE_SUSPENDED, environment.ptr, null, &si, &pi) == 0) return error.StartupExecFailed;
        defer _ = w.CloseHandle(pi.hThread);
        errdefer {
            _ = w.TerminateProcess(pi.hProcess, 1);
            _ = w.CloseHandle(pi.hProcess);
        }
        if (w.AssignProcessToJobObject(job, pi.hProcess) == 0) return error.JobFailed;
        if (w.ResumeThread(pi.hThread) == std.math.maxInt(w.DWORD)) return error.StartupExecFailed;
        return .{ .process = pi.hProcess, .job = job, .pipe = reader };
    }
    fn drain(self: *Job) void {
        var buffer: [4096]u8 = undefined;
        for (0..16) |_| {
            var available: w.DWORD = 0;
            if (w.PeekNamedPipe(self.pipe, null, 0, null, &available, null) == 0 or available == 0) break;
            var read: w.DWORD = 0;
            if (w.ReadFile(self.pipe, &buffer, @min(available, buffer.len), &read, null) == 0 or read == 0) break;
            const n = @min(read, self.output.len - self.used);
            @memcpy(self.output[self.used..][0..n], buffer[0..n]);
            self.used += n;
        }
    }
    pub fn check(self: *Job) ?c_int {
        if (self.done) return null;
        self.drain();
        if (w.WaitForSingleObject(self.process, 0) != w.WAIT_OBJECT_0) return null;
        self.drain();
        var status: w.DWORD = 1;
        _ = w.GetExitCodeProcess(self.process, &status);
        if (status != 0 and self.used > 0) std.log.err("startup script: {s}", .{self.output[0..self.used]});
        self.done = true;
        _ = w.CloseHandle(self.pipe);
        self.pipe = null;
        _ = w.CloseHandle(self.process);
        self.process = null;
        _ = w.CloseHandle(self.job);
        self.job = null;
        return @intCast(@min(status, 255));
    }
    pub fn deinit(self: *Job) void {
        if (self.done) return;
        _ = w.TerminateJobObject(self.job, 1);
        _ = w.WaitForSingleObject(self.process, 2000);
        _ = w.CloseHandle(self.pipe);
        _ = w.CloseHandle(self.process);
        _ = w.CloseHandle(self.job);
        self.done = true;
    }
};
