const std = @import("std");
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvToRgbImage = image_conversion.hsvToRgbImage;
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
    var mutable_conditions_copy = conditions;
    var condition_iterator = mutable_conditions_copy.iterator();
    var index: usize = 0;
    while (condition_iterator.next()) |entry| {
        defer index += 1;
        if (entry.value.*) {
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
    var conditions = std.EnumArray(ChromaticAberrationCondition, bool).initDefault(false, .{});
    const num_conditions = @typeInfo(ChromaticAberrationCondition).Enum.fields.len;

    // There aren't enough pixel values to meet all of the conditions so we can stop early
    if (hsv_pixel_buffer.len < num_conditions) {
        return false;
    }

    for (hsv_pixel_buffer, 0..) |hsv_pixel, pixel_index| {
        const possible_condition = _findNextUnmetCondition(conditions);
        const optional_next_unmet_condition = possible_condition.next_unmet_condition;
        const num_conditions_left = possible_condition.num_conditions_left;

        // We've met all the conditions (no more conditions) so we can stop early
        if (optional_next_unmet_condition == null) {
            return true;
        }

        // There aren't enough pixel values left to meet all of the conditions so we can
        // stop early
        if (hsv_pixel_buffer.len - pixel_index < num_conditions_left) {
            return false;
        }

        if (optional_next_unmet_condition) |next_unmet_condition| {
            switch (next_unmet_condition) {
                .blue => conditions.set(.blue, hsvPixelInRange(
                    hsv_pixel,
                    // OpenCV:
                    //  - h: [0, 180]
                    //  - s: [0, 255]
                    //  - v: [0, 255]
                    //
                    // OpenCV: (90, 34, 214)
                    HSVPixel.init(0.5, 0.133333, 0.839215),
                    // OpenCV: (152, 255, 255)
                    HSVPixel.init(0.844444, 1.0, 1.0),
                )),
                .cyan => conditions.set(.cyan, hsvPixelInRange(
                    hsv_pixel,
                    // OpenCV: (90, 34, 214)
                    HSVPixel.init(0.5, 0.133333, 0.839215),
                    // OpenCV: (136, 255, 255)
                    HSVPixel.init(0.755555, 1.0, 1.0),
                )),
                .yellow => conditions.set(.yellow, hsvPixelInRange(
                    hsv_pixel,
                    // OpenCV: (14, 20, 157)
                    HSVPixel.init(0.077777, 0.078843, 0.615686),
                    // OpenCV: (56, 195, 255)
                    HSVPixel.init(0.311111, 0.764705, 1.0),
                )),
                .red => conditions.set(.red, hsvPixelInRange(
                    hsv_pixel,
                    // OpenCV: (0, 50, 146)
                    HSVPixel.init(0.0, 0.196078, 0.572549),
                    // OpenCV: (14, 185, 255)
                    HSVPixel.init(0.077777, 0.725490, 1.0),
                ) or hsvPixelInRange(
                    hsv_pixel,
                    // OpenCV: (155, 56, 138)
                    HSVPixel.init(0.861111, 0.219607, 0.541176),
                    // OpenCV: (180, 202, 255)
                    HSVPixel.init(1.0, 0.792156, 1.0),
                )),
            }
        } else {
            @panic("Programmer error: We should have checked whether `optional_next_unmet_condition` " ++
                "was null before this point and return early because there are no more conditions to meet. " ++
                "This is a bug in the program itself (please report).");
        }
    }

    // Check that all conditions are met after looping through the buffer
    var condition_iterator = conditions.iterator();
    while (condition_iterator.next()) |entry| {
        if (!entry.value.*) {
            return false;
        }
    }

    return true;
}

pub fn findHaloChromaticAberrationText(hsv_image: HSVImage, allocator: std.mem.Allocator) !HSVImage {
    const output_hsv_pixels = try allocator.alloc(HSVPixel, hsv_image.pixels.len);
    @memset(output_hsv_pixels, HSVPixel{ .h = 0, .s = 0, .v = 0 });

    const buffer_size: usize = 6;

    // Look for Chromatic Aberration in the rows
    for (0..hsv_image.height) |y| {
        const row_start_pixel_index = y * hsv_image.width;
        const last_pixel_in_row_index = row_start_pixel_index + hsv_image.width;
        for (0..hsv_image.width) |x| {
            // Look at the next X pixels in the row
            const current_pixel_index = row_start_pixel_index + x;
            // Make sure to not over-run the end of the row
            const buffer_end_pixel_index = @min(current_pixel_index + buffer_size, last_pixel_in_row_index);
            const pixel_buffer = hsv_image.pixels[current_pixel_index..buffer_end_pixel_index];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                @memcpy(
                    output_hsv_pixels[current_pixel_index..buffer_end_pixel_index],
                    hsv_image.pixels[current_pixel_index..buffer_end_pixel_index],
                );
            }
        }
    }

    // Look for Chromatic Aberration in the columns
    var column_pixel_buffer = try allocator.alloc(HSVPixel, buffer_size);
    defer allocator.free(column_pixel_buffer);
    for (0..hsv_image.width) |x| {
        const last_pixel_in_column_index = (hsv_image.width * hsv_image.height) - (hsv_image.width - x);
        for (0..hsv_image.height) |y| {
            // Look at the next X pixels in the column
            var buffer_end_index: usize = 0;
            for (0..buffer_size) |i| {
                const current_pixel_index = (y + i) * hsv_image.width + x;
                // Make sure to not over-run the end of the column
                if (current_pixel_index >= last_pixel_in_column_index) {
                    break;
                }
                column_pixel_buffer[i] = hsv_image.pixels[current_pixel_index];
                buffer_end_index = i;
            }

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(column_pixel_buffer[0..buffer_end_index]);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                for (0..buffer_end_index) |i| {
                    const current_pixel_index = (y + i) * hsv_image.width + x;
                    output_hsv_pixels[current_pixel_index] = hsv_image.pixels[current_pixel_index];
                }
            }
        }
    }

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
        // Hard-coded values for the cropped image ("/home/eric/Downloads/36-1080-export-from-gimp.png")
        // 1410,
        // 877,
        // 40,
        // 26,
        allocator,
    );
    defer cropped_rgb_image.deinit(allocator);

    try cropped_rgb_image.saveImageToFilePath("/home/eric/Downloads/36-1080-export-from-gimp-cropped.png", allocator);

    const hsv_image = try rgbToHsvImage(cropped_rgb_image, allocator);
    defer hsv_image.deinit(allocator);

    const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
    defer chromatic_pattern_hsv_img.deinit(allocator);

    try chromatic_pattern_hsv_img.saveImageToFilePath(
        "/home/eric/Downloads/36-1080-export-from-gimp-chromatic-aberration-result1.png",
        allocator,
    );
}
