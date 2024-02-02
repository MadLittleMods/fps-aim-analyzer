const std = @import("std");
const image_conversion = @import("../vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const rgbPixelsfromHexArray = image_conversion.rgbPixelsfromHexArray;

fn repeatString(string: []const u8, repeat: usize, allocator: std.mem.Allocator) ![]const u8 {
    const resultant_string = try allocator.alloc(u8, repeat * string.len);
    for (0..repeat) |repeat_index| {
        for (0..string.len) |code_point_index| {
            const current_code_point_index = repeat_index * string.len + code_point_index;
            resultant_string[current_code_point_index] = string[code_point_index];
        }
    }

    return resultant_string;
}

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
    defer {
        if (optional_foreground_hex_color) |_| {
            allocator.free(foreground_color_code_string);
        }
    }

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
    defer {
        if (optional_background_hex_color) |_| {
            allocator.free(background_color_code_string);
        }
    }

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

pub const TerminalPrintingCharacter = struct {
    character: []const u8,
    /// Some characters render colors differently than others. For example, the full
    /// block character renders colors as-is but the nedium shade block characters render
    /// colors at 1/2 strength, etc respectively.
    opacity_compensation_factor: f64,
};

/// Given a pixel value from 0 to 255, return a unicode block character that represents
/// that pixel value (from nothing, to light shade, to medium shade, to dark shade, to
/// full block).
///
/// We use this in order to facilitate better copy/pasting from the terminal into a
/// plain-text document like a README, vary the characters so they look different from
/// each other.
///
/// See https://en.wikipedia.org/wiki/Block_Elements
fn getCharacterForPixelValue(
    /// Pixel value between 0.0 and 1.0
    pixel_value: f64,
) TerminalPrintingCharacter {
    var character: []const u8 = undefined;
    var opacity_compensation_factor: f64 = 1.0;
    if (pixel_value == 0) {
        // Just a space character that doesn't render anything but still ends up being
        // the same width in a monospace environment.
        character = " ";
        // opacity = 0.0;
        // No need to compensate since this character doesn't render any foreground color
        opacity_compensation_factor = 0.0;
    } else if (pixel_value < 0.25) {
        // Light shade character
        character = "\u{2591}";
        // opacity = 0.25;
        // 1 / 0.25 = 4
        opacity_compensation_factor = 4;
    } else if (pixel_value < 0.5) {
        // Medium shade character
        character = "\u{2592}";
        // opacity = 0.5;
        // 1 / 0.5 = 2
        opacity_compensation_factor = 2;
    } else if (pixel_value < 0.75) {
        // Dark shade character
        character = "\u{2593}";
        // opacity = 0.75;
        // 1 / 0.75 = 1.3333...
        opacity_compensation_factor = @as(f64, 1) / @as(f64, 0.75);
    } else {
        // Full block character
        character = "\u{2588}";
        // opacity = 1;
        // 1 / 1 = 1
        // No need to compensate since anything divided by 1 is itself
        opacity_compensation_factor = 1;
    }

    return .{
        .character = character,
        .opacity_compensation_factor = opacity_compensation_factor,
    };
}

/// Turn an image into a string of unicode block characters and ANSI escape codes to
/// visualize the pixel values in a terminal. This uses block/shade characters so it's
/// also useful for copy/pasting into a plain-text document like a README but also takes
/// up a lot of space since we have to use 2 characers per pixel to maintain a decent
/// aspect ratio.
pub fn allocPrintBlockImage(rgb_image: RGBImage, allocator: std.mem.Allocator) ![]const u8 {
    var width: usize = rgb_image.width;
    var height: usize = rgb_image.height;

    const hsv_image = try rgbToHsvImage(rgb_image, allocator);
    defer hsv_image.deinit(allocator);

    const row_strings = try allocator.alloc([]const u8, height);
    defer {
        for (row_strings) |row_string| {
            allocator.free(row_string);
        }
        allocator.free(row_strings);
    }

    const pixel_strings = try allocator.alloc([]const u8, width);
    defer allocator.free(pixel_strings);

    for (0..height) |row_index| {
        const row_start_index = row_index * width;
        for (0..width) |column_index| {
            const pixel_index = row_start_index + column_index;

            // FIXME: Perhaps we should instead use a grayscale image for better human
            // perception instead of HSV
            const pixel_character = getCharacterForPixelValue(hsv_image.pixels[pixel_index].v);
            const pixel_string = try std.fmt.allocPrint(
                allocator,
                // We use the same character twice to make it look more square and
                // preserve the aspect ratio (still not perfect though)
                "{0s}{0s}",
                .{pixel_character.character},
            );
            defer allocator.free(pixel_string);

            // Adjust the pixel value to compensate for the opacity of the block
            // character that we're using to represent it.
            const r: u8 = @intFromFloat(
                255 * (rgb_image.pixels[pixel_index].r * pixel_character.opacity_compensation_factor),
            );
            const g: u8 = @intFromFloat(
                255 * (rgb_image.pixels[pixel_index].g * pixel_character.opacity_compensation_factor),
            );
            const b: u8 = @intFromFloat(
                255 * (rgb_image.pixels[pixel_index].b * pixel_character.opacity_compensation_factor),
            );

            const colored_pixel_string = try decorateStringWithAnsiColor(
                pixel_string,
                // Assemble a hex color from the RGB values
                (@as(u24, r) << 16) |
                    (@as(u24, g) << 8) |
                    (@as(u24, b) << 0),
                0x000000,
                allocator,
            );
            pixel_strings[column_index] = colored_pixel_string;
        }

        const pixel_row_string = try std.mem.concat(allocator, u8, pixel_strings);
        defer allocator.free(pixel_row_string);
        defer {
            // After we're done with the pixel strings, clean them up
            for (pixel_strings) |pixel_string| {
                allocator.free(pixel_string);
            }
        }

        row_strings[row_index] = try std.fmt.allocPrint(
            allocator,
            "│{s}│\n",
            .{
                pixel_row_string,
            },
        );
    }

    const border_filler_string = try repeatString("─", width * 2, allocator);
    defer allocator.free(border_filler_string);
    const border_top_string = try std.fmt.allocPrint(allocator, "┌{s}┐\n", .{
        border_filler_string,
    });
    defer allocator.free(border_top_string);
    const border_bottom_string = try std.fmt.allocPrint(allocator, "└{s}┘", .{
        border_filler_string,
    });
    defer allocator.free(border_bottom_string);

    const main_image_string = try std.mem.concat(allocator, u8, row_strings);
    defer allocator.free(main_image_string);

    const resultant_string = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        border_top_string,
        main_image_string,
        border_bottom_string,
    });

    return resultant_string;
}

/// Turn an image into a string of unicode half-block characters and ANSI escape codes
/// to visualize the pixel values in a terminal. This takes up half the
/// horizontal/vertical real estate since we're able to pack in 1x2 pixels per character.
///
/// If you're looking for a plain-text copy/pasteable version, use `allocPrintImage`
/// which uses full-block/shade characeters but at the cost of taking up more
/// horizontal/vertical real estate.
pub fn allocPrintHalfBlockImage(rgb_image: RGBImage, allocator: std.mem.Allocator) ![]const u8 {
    var width: usize = rgb_image.width;
    var height: usize = rgb_image.height;

    const half_height_rows: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) / 2.0));
    const row_strings = try allocator.alloc([]const u8, half_height_rows);
    defer {
        for (row_strings) |row_string| {
            allocator.free(row_string);
        }
        allocator.free(row_strings);
    }

    const pixel_strings = try allocator.alloc([]const u8, width);
    defer allocator.free(pixel_strings);

    var row_index: usize = 0;
    var pixel_row_index: usize = 0;
    while (pixel_row_index < height) : ({
        row_index += 1;
        pixel_row_index += 2;
    }) {
        const pixel_row_start_index1 = pixel_row_index * width;
        const pixel_row_start_index2 = (pixel_row_index + 1) * width;
        for (0..width) |column_index| {
            const pixel_index1 = pixel_row_start_index1 + column_index;
            const pixel_index2 = pixel_row_start_index2 + column_index;

            const r1: u8 = @intFromFloat(255 * rgb_image.pixels[pixel_index1].r);
            const g1: u8 = @intFromFloat(255 * rgb_image.pixels[pixel_index1].g);
            const b1: u8 = @intFromFloat(255 * rgb_image.pixels[pixel_index1].b);

            const r2: u8 = if (pixel_row_index + 1 < height) @intFromFloat(255 * rgb_image.pixels[pixel_index2].r) else 0;
            const g2: u8 = if (pixel_row_index + 1 < height) @intFromFloat(255 * rgb_image.pixels[pixel_index2].g) else 0;
            const b2: u8 = if (pixel_row_index + 1 < height) @intFromFloat(255 * rgb_image.pixels[pixel_index2].b) else 0;

            const colored_pixel_string = try decorateStringWithAnsiColor(
                "\u{2584}",
                // Assemble a hex color from the RGB values
                (@as(u24, r2) << 16) |
                    (@as(u24, g2) << 8) |
                    (@as(u24, b2) << 0),
                (@as(u24, r1) << 16) |
                    (@as(u24, g1) << 8) |
                    (@as(u24, b1) << 0),
                allocator,
            );
            pixel_strings[column_index] = colored_pixel_string;
        }

        const pixel_row_string = try std.mem.concat(allocator, u8, pixel_strings);
        defer allocator.free(pixel_row_string);
        defer {
            // After we're done with the pixel strings, clean them up
            for (pixel_strings) |pixel_string| {
                allocator.free(pixel_string);
            }
        }

        row_strings[row_index] = try std.fmt.allocPrint(
            allocator,
            "|{s}|\n",
            .{
                pixel_row_string,
            },
        );
    }

    const border_filler_string = try repeatString("─", width, allocator);
    defer allocator.free(border_filler_string);
    const border_top_string = try std.fmt.allocPrint(allocator, "┌{s}┐\n", .{
        border_filler_string,
    });
    defer allocator.free(border_top_string);
    const border_bottom_string = try std.fmt.allocPrint(allocator, "└{s}┘", .{
        border_filler_string,
    });
    defer allocator.free(border_bottom_string);

    const main_image_string = try std.mem.concat(allocator, u8, row_strings);
    defer allocator.free(main_image_string);

    const resultant_string = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        border_top_string,
        main_image_string,
        border_bottom_string,
    });

    return resultant_string;
}

const KittyPixelFormat = enum {
    rgb,
    rgba,
    png,
};

const KittyAction = enum {
    transmit,
    transmit_and_display,
    query_terminal,
    display,
    delete,
    transmit_animation_data,
    control_animation,
    compose_animation,
};

pub fn allocPrintKittyImage(rgb_image: RGBImage, allocator: std.mem.Allocator) ![]const u8 {
    var pixel_bytes = try allocator.alloc(u8, rgb_image.width * rgb_image.height * 3);
    defer allocator.free(pixel_bytes);
    for (0..rgb_image.height) |row_index| {
        for (0..rgb_image.width) |column_index| {
            const pixel_index = row_index * rgb_image.width + column_index;
            const pixel = rgb_image.pixels[pixel_index];
            const pixel_byte_index = pixel_index * 3;
            pixel_bytes[pixel_byte_index] = @intFromFloat(255 * pixel.r);
            pixel_bytes[pixel_byte_index + 1] = @intFromFloat(255 * pixel.g);
            pixel_bytes[pixel_byte_index + 2] = @intFromFloat(255 * pixel.b);
        }
    }

    const pixel_format_control_code = switch (KittyPixelFormat.rgb) {
        .rgb => 24,
        .rgba => 32,
        .png => 100,
    };

    const action_control_code = switch (KittyAction.transmit_and_display) {
        .transmit => "t",
        .transmit_and_display => "T",
        .query_terminal => "q",
        // Also known as "put"
        .display => "p",
        .delete => "d",
        .transmit_animation_data => "f",
        .control_animation => "a",
        .compose_animation => "c",
    };

    const encoder = std.base64.standard.Encoder;
    var base64_buffer = try allocator.alloc(u8, encoder.calcSize(pixel_bytes.len));
    defer allocator.free(base64_buffer);
    const base64_payload = encoder.encode(base64_buffer, pixel_bytes);

    // Graphics escape code: <ESC>_G<control data>;<payload><ESC>\
    // <ESC> is just byte 27
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#control-data-reference
    return try std.fmt.allocPrint(allocator, "\u{001b}_Gf={},s={},v={},a={s};{s}\u{001b}\\", .{
        pixel_format_control_code,
        rgb_image.width,
        rgb_image.height,
        action_control_code,
        base64_payload,
    });
}

test "allocPrintKittyImage" {
    const allocator = std.testing.allocator;

    const kitty_output = try allocPrintKittyImage(
        .{
            .width = 20,
            .height = 20,
            .pixels = &rgbPixelsfromHexArray(&[_]u24{0xff0000} ** (20 * 20)),
        },
        allocator,
    );
    defer allocator.free(kitty_output);

    std.debug.print("allocPrintKittyImage\n{s}", .{
        kitty_output,
    });
}

pub const PrintType = enum {
    /// Print using full block/shade characters. This gives nice plain-text
    /// copy/pasteable output but takes up a lot of horizontal/vertical real estate since
    /// we use 2 characters per pixel to maintain a decent aspect ratio.
    full_block,
    /// Print using half block characters. This takes up half the horizontal/vertical
    /// real estate since we're able to pack in 1x2 pixels per character.
    half_block,
    // Print using the Kitty graphics protocol (seems the most widely supported actual
    // pixel display protocol for terminals at the moment).
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/
    kitty,
    // TODO: Print using the iTerm2 graphics protocol, https://iterm2.com/documentation-images.html
    // TODO: Print using Sixel graphic data
};

pub fn allocPrintImage(rgb_image: RGBImage, print_type: PrintType, allocator: std.mem.Allocator) ![]const u8 {
    return switch (print_type) {
        .full_block => allocPrintBlockImage(rgb_image, allocator),
        .half_block => allocPrintHalfBlockImage(rgb_image, allocator),
        .kitty => allocPrintKittyImage(rgb_image, allocator),
    };
}

/// Turn an image into a string of unicode block characters to visualize the pixel
/// values with a label tag above it.
pub fn allocPrintLabeledImage(
    label_string: []const u8,
    rgb_image: RGBImage,
    print_type: PrintType,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const top_filler_string = try repeatString("─", label_string.len, allocator);
    defer allocator.free(top_filler_string);

    const image_string = try allocPrintImage(rgb_image, print_type, allocator);
    defer allocator.free(image_string);

    const resultant_string = try std.fmt.allocPrint(allocator, "┌─{s}─┐\n│ {s} │\n{s}", .{
        top_filler_string,
        label_string,
        image_string,
    });

    return resultant_string;
}

/// Print an image to the terminal using unicode block characters to visualize the pixel
/// values.
pub fn printImage(rgb_image: RGBImage, print_type: PrintType, allocator: std.mem.Allocator) !void {
    const image_string = try allocPrintImage(rgb_image, print_type, allocator);
    defer allocator.free(image_string);
    std.debug.print("\n{s}\n", .{image_string});
}

/// Print an labeled image to the terminal using unicode block characters to visualize
/// the pixel values.
pub fn printLabeledImage(
    label_string: []const u8,
    rgb_image: RGBImage,
    print_type: PrintType,
    allocator: std.mem.Allocator,
) !void {
    const image_string = try allocPrintLabeledImage(
        label_string,
        rgb_image,
        print_type,
        allocator,
    );
    defer allocator.free(image_string);
    std.debug.print("\n{s}\n", .{image_string});
}
