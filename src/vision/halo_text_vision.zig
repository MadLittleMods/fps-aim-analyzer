const std = @import("std");
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const cropImage = image_conversion.cropImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvToRgbImage = image_conversion.hsvToRgbImage;
const hsvToBinaryImage = image_conversion.hsvToBinaryImage;
const hsvPixelInRange = image_conversion.hsvPixelInRange;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;
const decorateStringWithAnsiColor = print_utils.decorateStringWithAnsiColor;

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

pub fn checkForChromaticAberrationConditionInHsvPixel(hsv_pixel: HSVPixel, condition: ChromaticAberrationCondition) bool {
    return switch (condition) {
        .blue => hsvPixelInRange(
            hsv_pixel,
            // OpenCV:
            //  - h: [0, 180]
            //  - s: [0, 255]
            //  - v: [0, 255]
            //
            // OpenCV: (90, 34, 190)
            HSVPixel.init(0.5, 0.133333, 0.745098),
            // OpenCV: (152, 255, 255)
            HSVPixel.init(0.844444, 1.0, 1.0),
        ),
        .cyan => hsvPixelInRange(
            hsv_pixel,
            // OpenCV: (90, 34, 214)
            HSVPixel.init(0.5, 0.133333, 0.839215),
            // OpenCV: (136, 255, 255)
            HSVPixel.init(0.755555, 1.0, 1.0),
        ),
        .yellow => hsvPixelInRange(
            hsv_pixel,
            // OpenCV: (14, 20, 157)
            HSVPixel.init(0.077777, 0.078843, 0.615686),
            // OpenCV: (56, 195, 255)
            HSVPixel.init(0.311111, 0.764705, 1.0),
        ),
        .red => hsvPixelInRange(
            hsv_pixel,
            // OpenCV: (0, 50, 130)
            HSVPixel.init(0.0, 0.196078, 0.509803),
            // OpenCV: (14, 185, 255)
            HSVPixel.init(0.077777, 0.725490, 1.0),
        ) or hsvPixelInRange(
            hsv_pixel,
            // OpenCV: (155, 51, 138)
            HSVPixel.init(0.861111, 0.2, 0.541176),
            // OpenCV: (180, 202, 255)
            HSVPixel.init(1.0, 0.792156, 1.0),
        ),
    };
}

/// Checks for a series of blue, cyan, yellow, red pixels in order within a buffer which
/// indicates the chromatic aberration text in Halo.
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
            conditions.set(next_unmet_condition, checkForChromaticAberrationConditionInHsvPixel(
                hsv_pixel,
                next_unmet_condition,
            ));
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

    const total_pixels_in_image = hsv_image.width * hsv_image.height;

    const buffer_size: usize = 6;

    // Look for Chromatic Aberration in the rows
    for (0..hsv_image.height) |y| {
        const row_start_pixel_index = y * hsv_image.width;
        const row_end_pixel_index = row_start_pixel_index + hsv_image.width;
        for (0..hsv_image.width) |x| {
            // Look at the next X pixels in the row
            const current_pixel_index = row_start_pixel_index + x;
            // Make sure to not over-run the end of the row
            const buffer_end_pixel_index = @min(current_pixel_index + buffer_size, row_end_pixel_index);
            const pixel_buffer = hsv_image.pixels[current_pixel_index..buffer_end_pixel_index];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                @memcpy(
                    output_hsv_pixels[current_pixel_index..buffer_end_pixel_index],
                    hsv_image.pixels[current_pixel_index..buffer_end_pixel_index],
                );

                // TODO: There is a slight optimization we could additionally do by
                //       skipping over the pixels that we know are part of the chromatic
                //       aberration pattern. For example, if we find a match at index
                //       10, we know that *at least* the next 4 pixels are exclusively
                //       part of the this pattern. We could even skip to the pixel where
                //       the last condition was met.
            }
        }
    }

    // Look for Chromatic Aberration in the columns
    var column_pixel_buffer = try allocator.alloc(HSVPixel, buffer_size);
    defer allocator.free(column_pixel_buffer);
    for (0..hsv_image.width) |x| {
        for (0..hsv_image.height) |y| {
            // Look at the next X pixels in the column
            var column_pixel_buffer_size: usize = 0;
            for (0..buffer_size) |i| {
                const current_pixel_index = ((y + i) * hsv_image.width) + x;
                // Make sure to not over-run the end of the column
                if (current_pixel_index >= total_pixels_in_image) {
                    break;
                }
                column_pixel_buffer[i] = hsv_image.pixels[current_pixel_index];
                column_pixel_buffer_size = i + 1;
            }

            const pixel_buffer = column_pixel_buffer[0..column_pixel_buffer_size];

            // Check if the pixels in the buffer match the chromatic aberration pattern
            const has_chromatic_aberration = checkForChromaticAberrationInPixelBuffer(pixel_buffer);
            if (has_chromatic_aberration) {
                // Copy the pixels that match the chromatic aberration pattern from the buffer into the output
                for (0..column_pixel_buffer_size) |i| {
                    const current_pixel_index = ((y + i) * hsv_image.width) + x;
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

/// Assemble a string showing which chromatic aberration conditions are met for a given pixel
fn debugStringConditionsForPixel(hsv_pixel: HSVPixel, allocator: std.mem.Allocator) ![]const u8 {
    // Go over each pixel and make a little map showing which conditions are met
    const fields = @typeInfo(ChromaticAberrationCondition).Enum.fields;
    const condition_strings = try allocator.alloc([]const u8, fields.len);
    defer allocator.free(condition_strings);
    inline for (fields, 0..) |field, field_index| {
        const passes_condition = checkForChromaticAberrationConditionInHsvPixel(
            hsv_pixel,
            @field(ChromaticAberrationCondition, field.name),
        );
        condition_strings[field_index] = try decorateStringWithAnsiColor(
            if (passes_condition) "\u{29BF}" else " ",
            switch (@field(ChromaticAberrationCondition, field.name)) {
                .blue => 0x3383ff,
                .cyan => 0x35f5ff,
                .yellow => 0xd9f956,
                .red => 0xf95656,
            },
            null,
            allocator,
        );
    }

    // Combine the condition strings into a single string
    const condition_status_string = try std.mem.join(
        allocator,
        " ",
        condition_strings,
    );
    // After we're done with the condition strings, clean them up
    defer {
        for (condition_strings) |condition_string| {
            allocator.free(condition_string);
        }
    }

    return condition_status_string;
}

const FindHaloChromaticAberrationTextTestCase = struct {
    label: []const u8,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

test "findHaloChromaticAberrationText" {
    const allocator = std.testing.allocator;
    const rgb_image = try RGBImage.loadImageFromFilePath("screenshot-data/halo-infinite/1080/default/36.png", allocator);
    defer rgb_image.deinit(allocator);

    const test_cases = [_]FindHaloChromaticAberrationTextTestCase{
        // Three tests
        //
        .{
            .label = "Top terminal of the three (horizontal)",
            .x = 1424,
            .y = 829,
            .width = 4,
            .height = 1,
        },
        .{
            .label = "Top arm of the three (vertical)",
            .x = 1428,
            .y = 825,
            .width = 1,
            .height = 4,
        },
        .{
            .label = "Top arm of the three with margin above (vertical)",
            .x = 1428,
            .y = 823,
            .width = 1,
            .height = 6,
        },
        .{
            .label = "Top arm of the three with margin below (vertical)",
            .x = 1428,
            .y = 825,
            .width = 1,
            .height = 6,
        },
        .{
            .label = "Top stress of the three (horizonal)",
            .x = 1433,
            .y = 832,
            .width = 8,
            .height = 1,
        },
        .{
            .label = "Middle terminal of the three (vertical)",
            .x = 1430,
            .y = 831,
            .width = 1,
            .height = 8,
        },
        .{
            .label = "Bottom stress of the three (horizonal)",
            .x = 1434,
            .y = 840,
            .width = 6,
            .height = 1,
        },
        .{
            .label = "Bottom arm of the three (vertical)",
            .x = 1430,
            .y = 841,
            .width = 1,
            .height = 6,
        },
        // Six tests
        //
        .{
            .label = "Top terminal of the six (horizontal)",
            .x = 1451,
            .y = 829,
            .width = 6,
            .height = 1,
        },
        .{
            .label = "Top arm of the six (vertical)",
            .x = 1448,
            .y = 825,
            .width = 1,
            .height = 6,
        },
        .{
            .label = "Top stress of the six (horizontal)",
            .x = 1441,
            .y = 829,
            .width = 6,
            .height = 1,
        },
        .{
            .label = "Left-side of the bowl of the six (horizontal)",
            .x = 1442,
            .y = 838,
            .width = 6,
            .height = 1,
        },
        .{
            .label = "Right-side of the bowl of the six (horizontal)",
            .x = 1452,
            .y = 841,
            .width = 6,
            .height = 1,
        },
        .{
            .label = "Top-side of the bowl of the six (vertical)",
            .x = 1448,
            .y = 832,
            .width = 1,
            .height = 6,
        },
        .{
            .label = "Bottom-side of the bowl of the six (vertical)",
            .x = 1448,
            .y = 842,
            .width = 1,
            .height = 6,
        },
    };

    for (test_cases) |test_case| {
        const cropped_image = try cropImage(
            rgb_image,
            test_case.x,
            test_case.y,
            test_case.width,
            test_case.height,
            allocator,
        );
        defer cropped_image.deinit(allocator);

        const hsv_image = try rgbToHsvImage(cropped_image, allocator);
        defer hsv_image.deinit(allocator);

        // Function under test
        const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
        defer chromatic_pattern_hsv_img.deinit(allocator);

        // Get a binary version of the image so we can quickly check if any chromatic
        // aberration was copied over (`findHaloChromaticAberrationText` only copies
        // over pixels matching the chromatic aberration pattern are copied over)
        const chromatic_pattern_binary_mask = try hsvToBinaryImage(chromatic_pattern_hsv_img, allocator);
        defer chromatic_pattern_binary_mask.deinit(allocator);
        // Check if any chromatic aberration was found and copied over
        var found_chromatic_aberration = false;
        outer: for (0..chromatic_pattern_binary_mask.height) |y| {
            for (0..chromatic_pattern_binary_mask.width) |x| {
                const pixel_index = (y * chromatic_pattern_binary_mask.width) + x;
                const pixel = chromatic_pattern_binary_mask.pixels[pixel_index];
                if (pixel.value) {
                    found_chromatic_aberration = true;
                    break :outer;
                }
            }
        }

        // Return an error if no chromatic aberration was found and print out useful
        // debugging information
        if (!found_chromatic_aberration) {
            // Print a nice image to give some better context on what failed
            try printLabeledImage(
                test_case.label,
                cropped_image,
                allocator,
            );

            // Print a list of pixels in the image and which conditions each pixel meets
            for (hsv_image.pixels, 0..) |pixel, pixel_index| {
                const condition_status_string = try debugStringConditionsForPixel(pixel, allocator);
                defer allocator.free(condition_status_string);

                std.debug.print("\n\t{d: >3}: HSV({d:.6}, {d:.6}, {d:.6}) {s}", .{
                    pixel_index,
                    pixel.h,
                    pixel.s,
                    pixel.v,
                    condition_status_string,
                });
            }

            return error.UnableToFindChromaticAberration;
        }
    }
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
    const cropped_rgb_image = try cropImage(
        rgb_image,
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
