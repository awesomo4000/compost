const std = @import("std");
const terminal = @import("terminal");
pub const std_options: std.Options = .{ .log_level = .warn };

fn reply(_: *anyopaque, bytes: []const u8) !void {
    std.debug.print("Reply to child: {x}\n", .{bytes});
}

pub fn main(init: std.process.Init) !void {
    var context: u8 = 0;
    const surface = try terminal.Surface.create(init.io, init.gpa, .{ .columns = 40, .rows = 8, .cell_width = 8, .cell_height = 16 }, .{ .context = &context, .write = reply });
    defer surface.destroy();
    try surface.feed("A terminal surface\r\nUnicode: 世界\r\nprogress: 10%\rprogress: 90%");
    try surface.feed("\x1b[?1049hThis alternate screen is temporary\x1b[?1049l");
    try surface.feed("\x1b_Ga=T,f=24,s=1,v=1,i=42;/wAA\x1b\\");
    const text = try surface.plainText(init.gpa);
    defer init.gpa.free(text);
    std.debug.print("\nRetained screen:\n{s}\n\nImage 42 retained: {}\n", .{
        text,
        surface.terminal.screens.active.kitty_images.imageById(42) != null,
    });
}
