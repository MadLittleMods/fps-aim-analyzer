const std = @import("std");
const render_utils = @import("../utils/render_utils.zig");
const BoundingClientRect = render_utils.BoundingClientRect;
const image_conversion = @import("image_conversion.zig");
const HSVPixel = image_conversion.HSVPixel;
const HSVImage = image_conversion.HSVImage;
const RGBImage = image_conversion.RGBImage;
const cropImage = image_conversion.cropImage;
const maskImage = image_conversion.maskImage;
const convertToRgbImage = image_conversion.convertToRgbImage;
const rgbToHsvImage = image_conversion.rgbToHsvImage;
const hsvToRgbImage = image_conversion.hsvToRgbImage;
const hsvToBinaryImage = image_conversion.hsvToBinaryImage;
const checkHsvPixelInRange = image_conversion.checkHsvPixelInRange;
const morphological_operations = @import("morphological_operations.zig");
const getStructuringElement = morphological_operations.getStructuringElement;
const erode = morphological_operations.erode;
const dilate = morphological_operations.dilate;
const contours = @import("contours.zig");
const findContours = contours.findContours;
const traceContoursOnRgbImage = contours.traceContoursOnRgbImage;
const boundingRect = contours.boundingRect;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;
const decorateStringWithAnsiColor = print_utils.decorateStringWithAnsiColor;

/// Basically representing the stage of cropping the process is at
pub const ScreenshotRegion = enum {
    full_screen,
    /// Cropped bottom-right quadrant of the screen
    bottom_right_quadrant,
    /// Bounding box around the UI in the bottom-right
    bottom_right_ui,
    /// Bounding box specifically around the ammo counter in the bottom-right
    ammo_counter,

    /// Bounding box around the UI in the center of the screen where the reticle is
    center,
};

pub fn Screenshot(comptime ImageType: type) type {
    return struct {
        image: ImageType,
        region: ScreenshotRegion,
    };
}

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
        .blue => checkHsvPixelInRange(
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
        .cyan => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (90, 34, 214)
            HSVPixel.init(0.5, 0.133333, 0.839215),
            // OpenCV: (136, 255, 255)
            HSVPixel.init(0.755555, 1.0, 1.0),
        ),
        .yellow => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (14, 20, 157)
            HSVPixel.init(0.077777, 0.078843, 0.615686),
            // OpenCV: (56, 195, 255)
            HSVPixel.init(0.311111, 0.764705, 1.0),
        ),
        .red => checkHsvPixelInRange(
            hsv_pixel,
            // OpenCV: (0, 50, 130)
            HSVPixel.init(0.0, 0.196078, 0.509803),
            // OpenCV: (14, 185, 255)
            HSVPixel.init(0.077777, 0.725490, 1.0),
        ) or checkHsvPixelInRange(
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
    errdefer allocator.free(output_hsv_pixels);
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
fn _debugStringConditionsForPixel(hsv_pixel: HSVPixel, allocator: std.mem.Allocator) ![]const u8 {
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
                .full_block,
                allocator,
            );

            // Print a list of pixels in the image and which conditions each pixel meets
            for (hsv_image.pixels, 0..) |pixel, pixel_index| {
                const condition_status_string = try _debugStringConditionsForPixel(pixel, allocator);
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

pub const IsolateDiagnostics = struct {
    images: std.StringArrayHashMap(RGBImage),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.images) |image| {
            image.deinit(allocator);
        }
        allocator.free(self.images);
    }

    pub fn addImage(self: *@This(), label: []const u8, image: anytype, allocator: std.mem.Allocator) !void {
        const rgb_image = try convertToRgbImage(image, allocator);
        try self.images.put(label, rgb_image);
    }
};

/// Given a screenshot of Halo Infinite, isolate the ammo counter region.
pub fn isolateHaloAmmoCounter(
    screenshot: Screenshot(RGBImage),
    diagnostics: ?*IsolateDiagnostics,
    allocator: std.mem.Allocator,
) !?[]const RGBImage {
    // Crop the image so we have less to work with.
    // After this step, we will have to deal with 1/4 of the image or less.
    const cropped_screenshot = try switch (screenshot.region) {
        .full_screen => blk: {
            // Crop to the bottom-right quadrant (where the ammo count is)
            const half_width = @divFloor(screenshot.image.width, 2);
            const half_height = @divFloor(screenshot.image.height, 2);
            const cropped_rgb_image = try cropImage(
                screenshot.image,
                half_width,
                half_height,
                screenshot.image.width - half_width,
                screenshot.image.height - half_height,
                // TODO: Remove -- Hard-coded values for the cropped image ("/home/eric/Downloads/36-1080-export-from-gimp.png")
                // 1410,
                // 877,
                // 40,
                // 26,
                allocator,
            );
            break :blk Screenshot(RGBImage){
                .image = cropped_rgb_image,
                .region = .bottom_right_quadrant,
            };
        },
        // No need to do anything if we're already in the bottom-right quadrant or
        // something more specific
        .bottom_right_quadrant, .bottom_right_ui, .ammo_counter => screenshot,
        // Other regions do not contain the ammo counter so it's impossible for us to
        // do anything
        .center => error.ScreenshotRegionDoesNotContainAmmoCounter,
    };
    defer {
        switch (screenshot.region) {
            .full_screen => {
                cropped_screenshot.image.deinit(allocator);
            },
            else => {},
        }
    }
    // Debug: Pixels after cropping
    if (diagnostics) |diag| {
        try diag.addImage("cropped_screenshot", cropped_screenshot.image, allocator);
    }

    const hsv_image = try rgbToHsvImage(cropped_screenshot.image, allocator);
    defer hsv_image.deinit(allocator);

    // Find the chromatic aberration text
    const chromatic_pattern_hsv_img = try findHaloChromaticAberrationText(hsv_image, allocator);
    defer chromatic_pattern_hsv_img.deinit(allocator);
    // Debug: Pixels after finding chromatic aberration pattern
    if (diagnostics) |diag| {
        try diag.addImage("chromatic_pattern_hsv_img", chromatic_pattern_hsv_img, allocator);
    }

    // Erode and dilate (open). Erode the mask to get rid of some of the smaller
    // chromatic aberration captures that aren't the text we want. Dilate the mask to
    // connect the text characters.
    const chromatic_pattern_opened_mask = opened_mask: {
        const chromatic_pattern_binary_mask = try hsvToBinaryImage(chromatic_pattern_hsv_img, allocator);
        defer chromatic_pattern_binary_mask.deinit(allocator);

        // Erode the mask to get rid of some of the smaller chromatic aberration captures
        const erode_kernel = try getStructuringElement(
            .cross,
            3,
            3,
            allocator,
        );
        defer erode_kernel.deinit(allocator);
        const chromatic_pattern_eroded_mask = try erode(
            chromatic_pattern_binary_mask,
            erode_kernel,
            allocator,
        );
        defer chromatic_pattern_eroded_mask.deinit(allocator);
        // Debug: After eroding
        {
            const eroded_chromatic_pattern_rgb_image = try maskImage(
                cropped_screenshot.image,
                chromatic_pattern_eroded_mask,
                allocator,
            );
            defer eroded_chromatic_pattern_rgb_image.deinit(allocator);
            // Debug: Pixels after eroding
            if (diagnostics) |diag| {
                try diag.addImage("eroded_chromatic_pattern_rgb_image", eroded_chromatic_pattern_rgb_image, allocator);
            }
        }

        // Create a horizontal kernel and dilate to connect text characters
        const dilate_kernel = try getStructuringElement(
            .rectangle,
            3,
            9,
            allocator,
        );
        defer dilate_kernel.deinit(allocator);
        const chromatic_pattern_dilated_mask = try dilate(
            chromatic_pattern_eroded_mask,
            dilate_kernel,
            allocator,
        );
        // defer chromatic_pattern_dilated_mask.deinit(allocator);

        break :opened_mask chromatic_pattern_dilated_mask;
    };
    defer chromatic_pattern_opened_mask.deinit(allocator);

    // Find the contours in the opened mask
    const chromatic_contours = try findContours(
        chromatic_pattern_opened_mask,
        .square,
        allocator,
    );
    defer {
        for (chromatic_contours) |contour| {
            allocator.free(contour);
        }
        allocator.free(chromatic_contours);
    }
    // Debug: ...
    if (diagnostics) |diag| {
        // Debug: Pixels after opening (erode/dilate)
        const opened_chromatic_pattern_rgb_image = try maskImage(
            cropped_screenshot.image,
            chromatic_pattern_opened_mask,
            allocator,
        );
        defer opened_chromatic_pattern_rgb_image.deinit(allocator);
        try diag.addImage("opened_chromatic_pattern_rgb_image", opened_chromatic_pattern_rgb_image, allocator);

        // Debug: Trace contours
        const traced_rgb_image = try traceContoursOnRgbImage(
            opened_chromatic_pattern_rgb_image,
            chromatic_contours,
            allocator,
        );
        defer traced_rgb_image.deinit(allocator);
        try diag.addImage("contour_traced_rgb_image", traced_rgb_image, allocator);
    }

    const character_min_width = 14;
    const character_min_height = 21;
    // We only expect 2-3 characters in the ammo counter most of the time. 4 characters
    // seems possible and 5 doesn't seem like it will happen at all.
    const max_num_ammo_characters = 5;

    // Find the bounding boxes around the contours that are big enough to be characters
    var num_ammo_characters: u4 = 0;
    var ammo_digit_bounding_boxes = [max_num_ammo_characters]BoundingClientRect(usize){
        undefined, undefined, undefined, undefined, undefined,
    };
    for (chromatic_contours) |contour| {
        const bounding_box = boundingRect(contour);
        // Only consider bounding boxes that are big enough to be characters
        const is_character_sized_bounding_box = bounding_box.width > character_min_width and bounding_box.height > character_min_height;
        if (is_character_sized_bounding_box) {
            ammo_digit_bounding_boxes[num_ammo_characters] = bounding_box;
            num_ammo_characters += 1;

            // Stop after we find the max number of characters we expect
            if (num_ammo_characters >= max_num_ammo_characters) {
                break;
            }
        }
        // We expect the ammo counter bounding boxes to be consecutive so if we find a
        // bounding box that is too small after we already found some digits, we can
        // stop looking for more
        else if (!is_character_sized_bounding_box and num_ammo_characters > 0) {
            break;
        }
    }

    if (num_ammo_characters > 0) {
        var ammo_digit_rgb_images = try allocator.alloc(RGBImage, num_ammo_characters);
        for (ammo_digit_bounding_boxes[0..num_ammo_characters], ammo_digit_rgb_images) |bounding_box, *ammo_digit_rgb_image| {
            ammo_digit_rgb_image.* = try cropImage(
                cropped_screenshot.image,
                bounding_box.x,
                bounding_box.y,
                bounding_box.width,
                bounding_box.height,
                allocator,
            );
        }

        return ammo_digit_rgb_images;
    }

    return null;
}

test "Find Halo ammo counter region" {
    const allocator = std.testing.allocator;
    const rgb_image = try RGBImage.loadImageFromFilePath("/home/eric/Downloads/36-1080-export-from-gimp.png", allocator);
    defer rgb_image.deinit(allocator);

    const maybe_ammo_cropped_digits = try isolateHaloAmmoCounter(
        .{
            .image = rgb_image,
            .region = .full_screen,
        },
        null,
        allocator,
    );
    try std.testing.expect(maybe_ammo_cropped_digits != null);
    defer if (maybe_ammo_cropped_digits) |ammo_cropped_digits| {
        for (ammo_cropped_digits) |ammo_cropped_digit| {
            ammo_cropped_digit.deinit(allocator);
        }
        allocator.free(ammo_cropped_digits);
    };

    if (maybe_ammo_cropped_digits) |ammo_cropped_digits| {
        try std.testing.expect(ammo_cropped_digits.len == 2);

        for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
            const digit_label = try std.fmt.allocPrint(allocator, "Digit {}", .{digit_index});
            defer allocator.free(digit_label);
            try printLabeledImage(digit_label, ammo_cropped_digit, .half_block, allocator);
        }
    }
}
