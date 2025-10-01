const std = @import("std");

pub fn repeatString(string: []const u8, repeat: usize, allocator: std.mem.Allocator) ![]const u8 {
    const resultant_string = try allocator.alloc(u8, repeat * string.len);
    for (0..repeat) |repeat_index| {
        for (0..string.len) |code_point_index| {
            const current_code_point_index = repeat_index * string.len + code_point_index;
            resultant_string[current_code_point_index] = string[code_point_index];
        }
    }

    return resultant_string;
}

pub fn findLengthOfPrintedValue(value: usize, comptime format: []const u8, allocator: std.mem.Allocator) !usize {
    const string = try std.fmt.allocPrint(allocator, format, .{value});
    defer allocator.free(string);

    return string.len;
}
