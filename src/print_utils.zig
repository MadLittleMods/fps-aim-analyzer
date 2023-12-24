const std = @import("std");

/// Add ANSI escape codes to around a given string to make it a certain RGB color in the terminal
pub fn decorateStringWithAnsiColor(
    input_string: []const u8,
    /// Example: `0xFFFFFF`
    optional_foreground_hex_color: ?u24,
    optional_background_hex_color: ?u24,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var foreground_color_code_string: []const u8 = "";
    if (optional_foreground_hex_color) |foreground_hex_color| {
        foreground_color_code_string = try std.fmt.allocPrint(
            allocator,
            "38;2;{d};{d};{d}",
            .{
                // Red channel:
                // Shift the hex color right 16 bits to get the red component all the way down,
                // then make sure we only select the lowest 8 bits by using `& 0xFF`
                (foreground_hex_color >> 16) & 0xFF,
                // Greeen channel:
                // Shift the hex color right 8 bits to get the green component all the way down,
                // then make sure we only select the lowest 8 bits by using `& 0xFF`
                (foreground_hex_color >> 8) & 0xFF,
                // Blue channel:
                // No need to shift the hex color to get the blue component all the way down,
                // but we still need to make sure we only select the lowest 8 bits by using `& 0xFF`
                foreground_hex_color & 0xFF,
            },
        );
    }
    defer allocator.free(foreground_color_code_string);

    var background_color_code_string: []const u8 = "";
    if (optional_background_hex_color) |background_hex_color| {
        background_color_code_string = try std.fmt.allocPrint(
            allocator,
            "48;2;{d};{d};{d}",
            .{
                // Red channel:
                // Shift the hex color right 16 bits to get the red component all the way down,
                // then make sure we only select the lowest 8 bits by using `& 0xFF`
                (background_hex_color >> 16) & 0xFF,
                // Greeen channel:
                // Shift the hex color right 8 bits to get the green component all the way down,
                // then make sure we only select the lowest 8 bits by using `& 0xFF`
                (background_hex_color >> 8) & 0xFF,
                // Blue channel:
                // No need to shift the hex color to get the blue component all the way down,
                // but we still need to make sure we only select the lowest 8 bits by using `& 0xFF`
                background_hex_color & 0xFF,
            },
        );
    }
    defer allocator.free(background_color_code_string);

    var possible_combinator_string: []const u8 = "";
    if (optional_foreground_hex_color != null and optional_background_hex_color != null) {
        possible_combinator_string = ";";
    }

    const string = try std.fmt.allocPrint(
        allocator,
        "\u{001b}[{s}{s}{s}m{s}\u{001b}[0m",
        .{
            foreground_color_code_string,
            possible_combinator_string,
            background_color_code_string,
            input_string,
        },
    );

    return string;
}
