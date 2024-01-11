const std = @import("std");
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvPixelInRange = image_conversion.hsvPixelInRange;

pub const ChromaticAberrationCondition = enum {
    blue,
    cyan,
    yellow,
    red,
};

const PossibleCondition = struct {
    next_unmet_condition: ?ChromaticAberrationCondition,
    num_conditions_left: usize,
};

fn _findNextUnmetCondition(conditions: std.EnumArray(ChromaticAberrationCondition, bool)) PossibleCondition {
    var condition_iterator = conditions.iterator();
    var index: usize = 0;
    while (condition_iterator.next()) |entry| {
        defer index += 1;
        if (entry.value) {
            continue;
        }

        const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;
        return .{
            .next_unmet_condition = entry.key,
            .num_conditions_left = num_conditions - index,
        };
    }

    return .{
        .next_unmet_condition = null,
        .num_conditions_left = 0,
    };
}

pub fn checkForChromaticAberrationInPixelBuffer(hsv_pixel_buffer: []const HSVPixel) bool {
    // We want to check to see that the following conditions are met in order
    const conditions = std.EnumArray(ChromaticAberrationCondition, bool).initDefault(
        false,
    );
    const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;

    // There aren't enough pixel values to meet all of the conditions so we can stop early
    if (hsv_pixel_buffer.len < num_conditions) {
        return false;
    }

    for (hsv_pixel_buffer, 0..) |pixel_index, hsv_pixel| {
        const possible_condition = _findNextUnmetCondition(conditions);
        const next_unmet_condition = possible_condition.next_unmet_condition;
        const num_conditions_left = possible_condition.num_conditions_left;

        // We've met all the conditions so we can stop early
        if (next_unmet_condition == null) {
            return true;
        }

        // There aren't enough pixel values left to meet all of the conditions so we can
        // stop early
        if (hsv_pixel_buffer.len - pixel_index < num_conditions_left) {
            return false;
        }

        switch (next_unmet_condition) {
            .blue => conditions.set(.blue, hsvPixelInRange(
                hsv_pixel,
                .{ .h = 90, .s = 34, .v = 214 },
                .{ .h = 152, .s = 255, .v = 255 },
            )),
            .cyan => conditions.set(.cyan, hsvPixelInRange(
                hsv_pixel,
                .{ .h = 90, .s = 34, .v = 214 },
                .{ .h = 136, .s = 255, .v = 255 },
            )),
            .yellow => conditions.set(.yellow, hsvPixelInRange(
                hsv_pixel,
                .{ .h = 14, .s = 20, .v = 157 },
                .{ .h = 56, .s = 195, .v = 255 },
            )),
            .red => conditions.set(.red, hsvPixelInRange(
                hsv_pixel,
                .{ .h = 0, .s = 50, .v = 146 },
                .{ .h = 14, .s = 185, .v = 255 },
            ) or hsvPixelInRange(hsv_pixel, .{ .h = 155, .s = 56, .v = 138 }, .{ .h = 180, .s = 202, .v = 255 })),
        }
    }

    // Check that all conditions are met after looping through the buffer
    var condition_iterator = conditions.iterator();
    while (condition_iterator.next()) |entry| {
        if (!entry.value) {
            return false;
        }
    }

    return true;
}

pub fn findHaloChromaticAberrationText(hsv_image: HSVImage, allocator: std.mem.Allocator) HSVImage {
    const output_hsv_pixels = try allocator.alloc(HSVPixel, hsv_image.pixels.len);

    const buffer_limit: usize = 10;
    const hsv_pixel_buffer = std.ArrayList(HSVPixel).initCapacity(allocator, buffer_limit);
    defer hsv_pixel_buffer.deinit();

    // Look for Chromatic Aberration in the rows
    for (0..hsv_image.height) |y| {
        for (0..hsv_image.width) |x| {
            // Keep track of the last X pixels in the buffer (FIFO)
            if (hsv_pixel_buffer.items.len > buffer_limit) {
                hsv_pixel_buffer.pop(0);
            }
            const current_pixel_index = y * hsv_image.width + x;
            hsv_pixel_buffer.append(hsv_image.pixels[current_pixel_index]);

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(hsv_pixel_buffer.items);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                const buffer_start_pixel_index = y * hsv_image.width + (x - hsv_pixel_buffer.items.len);
                @memset(
                    output_hsv_pixels[buffer_start_pixel_index..current_pixel_index],
                    hsv_image.pixels[buffer_start_pixel_index..current_pixel_index],
                );
            }
        }
    }

    // TODO: Look for Chromatic Aberration in the columns

    return .{
        .width = hsv_image.width,
        .height = hsv_image.height,
        .pixels = output_hsv_pixels,
    };
}

test "asdf" {
    // std.debug.assert(std.fs.path.isAbsolute(abs_dir_path));
    // var iterable_dir = try fs.openDirAbsolute(abs_dir_path, .{ .iterate = true });
    // defer iterable_dir.close();

    // var it = iterable_dir.iterate();
    // while (try it.next()) |entry| {
    //     switch (entry.kind) {
    //         .file, .sym_link => {},
    //         else => continue,
    //     }

    //     // entry.name;
    // }

    const allocator = std.testing.allocator;
    const rgb_image = try RGBImage.loadImageFromFilePath("/home/eric/Downloads/36-1080-export-from-gimp.png", allocator);
    defer rgb_image.deinit(allocator);

    const half_width = @divFloor(rgb_image.width, 2);
    const half_height = @divFloor(rgb_image.height, 2);
    const cropped_rgb_image = try rgb_image.crop(
        // Bottom-right corner (where the ammo count is)
        half_width,
        half_height,
        rgb_image.width - half_width,
        rgb_image.height - half_height,
        allocator,
    );
    defer cropped_rgb_image.deinit(allocator);

    // try cropped_rgb_image.saveImageToFilePath("/home/eric/Downloads/36-1080-export-from-gimp-cropped.png", allocator);

    const hsv_image = rgbToHsvImage(cropped_rgb_image, allocator);

    const chromatic_pattern_hsv_img = findHaloChromaticAberrationText(hsv_image, allocator);
    _ = chromatic_pattern_hsv_img;
}
