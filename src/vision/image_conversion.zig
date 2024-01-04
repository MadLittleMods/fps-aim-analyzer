const std = @import("std");
const zigimg = @import("zigimg");

fn asdf(allocator: std.mem.Allocator) !void {
    var img = try zigimg.Image.fromFilePath(allocator, "asdf.png");
    defer img.deinit();

    std.log.debug("asdf {}", .{
        img.pixels,
    });
}

test "asdf" {
    const allocator = std.testing.allocator;
    try asdf(allocator);
}
