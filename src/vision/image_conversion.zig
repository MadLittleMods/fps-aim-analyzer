const std = @import("std");
const zigimg = @import("zigimg");
const assertions = @import("../utils/assertions.zig");
const comptime_assert = assertions.comptime_assert;
const approxEqAbs = assertions.approxEqAbs;

/// All values are in the range [0, 1]
pub const RGBPixel = struct {
    r: f32,
    g: f32,
    b: f32,

    /// Usage: RGBPixel.fromHexNumber(0x4ae728)
    pub fn fromHexNumber(hex_color: u24) RGBPixel {
        // Red channel:
        // Shift the hex color right 16 bits to get the red component all the way down,
        // then make sure we only select the lowest 8 bits by using `& 0xFF`
        const red = (hex_color >> 16) & 0xFF;
        // Greeen channel:
        // Shift the hex color right 8 bits to get the green component all the way down,
        // then make sure we only select the lowest 8 bits by using `& 0xFF`
        const green = (hex_color >> 8) & 0xFF;
        // Blue channel:
        // No need to shift the hex color to get the blue component all the way down,
        // but we still need to make sure we only select the lowest 8 bits by using `& 0xFF`
        const blue = hex_color & 0xFF;

        // Convert from [0, 255] to [0, 1]
        return RGBPixel{
            .r = @as(f32, @floatFromInt(red)) / 255.0,
            .g = @as(f32, @floatFromInt(green)) / 255.0,
            .b = @as(f32, @floatFromInt(blue)) / 255.0,
        };
    }
};

fn testRgbApproxEqAbs(expected: RGBPixel, actual: RGBPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
}

fn testHsvApproxEqAbs(expected: HSVPixel, actual: HSVPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.s, actual.s, tolerance);
    try std.testing.expectApproxEqAbs(expected.v, actual.v, tolerance);
}

test "RGBPixel.fromHexNumber" {
    // White
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 1.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0xffffff),
        1e-4,
    );
    // Black
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x000000),
        1e-4,
    );
    // Red
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0xff0000),
        1e-4,
    );
    // Green
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 1.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x00ff00),
        1e-4,
    );
    // Blue
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0x0000ff),
        1e-4,
    );

    // Green-ish
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 0.290196, .g = 0.905882, .b = 0.156862 },
        RGBPixel.fromHexNumber(0x4ae728),
        1e-4,
    );
    // Blue-ish
    try testRgbApproxEqAbs(
        RGBPixel{ .r = 0.239215, .g = 0.431372, .b = 0.647058 },
        RGBPixel.fromHexNumber(0x3d6ea5),
        1e-4,
    );
}

/// All values are in the range [0, 1]
pub const HSVPixel = struct {
    h: f32,
    s: f32,
    v: f32,
};

pub const RGBImage = struct {
    width: usize,
    height: usize,
    /// Row-major order (line by line)
    pixels: []const RGBPixel,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn loadImageFromFilePath(image_file_path: []const u8, allocator: std.mem.Allocator) !@This() {
        var img = try zigimg.Image.fromFilePath(allocator, image_file_path);
        defer img.deinit();

        const output_rgb_pixels = try allocator.alloc(RGBPixel, img.pixels.len());
        switch (img.pixels) {
            .rgb24 => |rgb_pixels| {
                for (rgb_pixels, output_rgb_pixels) |pixel, *output_rgb_pixel| {
                    const zigimg_color_f32 = pixel.toColorf32();
                    output_rgb_pixel.* = RGBPixel{
                        .r = zigimg_color_f32.r,
                        .g = zigimg_color_f32.g,
                        .b = zigimg_color_f32.b,
                    };
                }
            },
            else => {
                return error.UnsupportedPixelFormat;
            },
        }

        // img.rawBytes();
        // img.pixels.asBytes()

        return .{
            .width = img.width,
            .height = img.height,
            .pixels = output_rgb_pixels,
        };
    }

    pub fn saveImageToFilePath(self: *const @This(), image_file_path: []const u8, allocator: std.mem.Allocator) !void {
        var img = try zigimg.Image.create(
            allocator,
            self.width,
            self.height,
            .rgb24,
        );
        defer img.deinit();

        for (img.pixels.rgb24, self.pixels) |*output_pixel, pixel| {
            output_pixel.* = zigimg.color.Rgb24{
                .r = @as(u8, @as(u8, @intFromFloat(pixel.rgb.r * 255.0))),
                .g = @as(u8, @as(u8, @intFromFloat(pixel.rgb.g * 255.0))),
                .b = @as(u8, @as(u8, @intFromFloat(pixel.rgb.b * 255.0))),
            };
        }

        try img.writeToFilePath(image_file_path, .{ .png = .{} });
    }

    pub fn crop(
        self: *const @This(),
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        allocator: std.mem.Allocator,
    ) !@This() {
        var output_rgb_pixels = try allocator.alloc(RGBPixel, width * height);
        for (0..height) |crop_y| {
            for (0..width) |crop_x| {
                const src_x = x + crop_x;
                const src_y = y + crop_y;
                output_rgb_pixels[crop_y * width + crop_x] = self.pixels[src_y * self.width + src_x];
            }
        }

        return .{
            .width = width,
            .height = height,
            .pixels = output_rgb_pixels,
        };
    }
};

pub const HSVImage = struct {
    width: usize,
    height: usize,
    /// Row-major order (line by line)
    pixels: []const HSVPixel,
};

// Before the hue (h) is scaled, it has a range of [-1, 5) that we need to scale to
// [0, 360) if we want degrees or [0, 1) if we want it normalized.
const h_raw_lower_bound = -1.0;
const h_raw_upper_bound = 5.0;
const h_raw_range = h_raw_upper_bound - h_raw_lower_bound;

const h_degree_upper_bound = 360.0;
const h_degree_scaler = h_degree_upper_bound / h_raw_range;

const h_normalized_upper_bound = 1.0;
const h_normalized_scaler = h_normalized_upper_bound / h_raw_range;

comptime {
    // Just sanity check that comptime math worked out
    comptime_assert(h_degree_scaler == 60, h_degree_scaler);

    comptime_assert(
        approxEqAbs(comptime_float, h_normalized_scaler, 0.1666666, 1e-4),
        h_normalized_scaler,
    );
}

/// Convert an RGB pixel to an HSV pixel.
///
// Based on https://stackoverflow.com/questions/3018313/algorithm-to-convert-rgb-to-hsv-and-hsv-to-rgb-in-range-0-255-for-both/6930407#6930407
// Other notes: https://cs.stackexchange.com/questions/64549/convert-hsv-to-rgb-colors/127918#127918
// Other implementation where I picked up some comment explanations, https://github.com/nitrogenez/prism/blob/9152942425546f6110bd0202d7671d6ff5b25de5/src/spaces/HSV.zig#L9-L40
pub fn rgbToHsvPixel(rgb_pixel: RGBPixel) HSVPixel {
    // TODO: Check if RGB is normalized [0, 1]

    const r = rgb_pixel.r;
    const g = rgb_pixel.g;
    const b = rgb_pixel.b;

    const max = @max(r, g, b);
    const min = @min(r, g, b);
    // Also known as "chroma"
    const delta = max - min;

    const v: f32 = max;
    // If this is just a shade of grey, return early. When the color is black, we also
    // avoid a divide by zero (`max == 0`) in the saturation calculation.
    if (delta < 0.00001 or max < 0.00001) {
        return HSVPixel{
            .h = 0,
            .s = 0,
            .v = v,
        };
    }

    const s: f32 = (delta / max);

    // Find which color is the max.
    //
    // Before we scale `h_raw`, it is in the range [-1, 5) where:
    //  - [−1, 1) when the max is R,
    //  - [ 1, 3) when the max is G,
    //  - [ 3, 5) when the max is B,
    var h_raw: f32 = 0.0;
    if (r == max) {
        // between yellow & magenta
        h_raw = 0.0 + (g - b) / delta;
    } else if (g == max) {
        // between cyan & yellow
        h_raw = 2.0 + (b - r) / delta;
    } else {
        // between magenta & cyan
        h_raw = 4.0 + (r - g) / delta;
    }

    // Scale to [0, 1)
    // If we wanted to scale to [0, 360), we would multiply instead by `h_degree_scaler` (60)
    var h = h_raw * h_normalized_scaler;

    // Wrap around if negative
    if (h < 0.0) {
        h += h_normalized_upper_bound;
    }

    return HSVPixel{
        .h = h,
        .s = s,
        .v = v,
    };
}

/// Convert an HSV pixel to an RGB pixel.
///
// Based on https://stackoverflow.com/questions/24852345/hsv-to-rgb-color-conversion/26856771#26856771
// Other: https://github.com/wjakob/instant-meshes/blob/7b3160864a2e1025af498c84cfed91cbfb613698/src/common.h#L358-L376
pub fn hsvToRgbPixel(hsv_pixel: HSVPixel) RGBPixel {
    if (hsv_pixel.s == 0.0) {
        // Achromatic (grey)
        return RGBPixel{
            .r = hsv_pixel.v,
            .g = hsv_pixel.v,
            .b = hsv_pixel.v,
        };
    }

    const h_scaled = hsv_pixel.h * 6.0;
    const h_scaled_floor = @floor(h_scaled);
    const fractional_part_of_h = h_scaled - h_scaled_floor;

    const p = hsv_pixel.v * (1.0 - hsv_pixel.s);
    const q = hsv_pixel.v * (1.0 - hsv_pixel.s * fractional_part_of_h);
    const t = hsv_pixel.v * (1.0 - hsv_pixel.s * (1.0 - fractional_part_of_h));

    switch (@as(u3, @intFromFloat(h_scaled_floor))) {
        0 => return .{ .r = hsv_pixel.v, .g = t, .b = p },
        1 => return .{ .r = q, .g = hsv_pixel.v, .b = p },
        2 => return .{ .r = p, .g = hsv_pixel.v, .b = t },
        3 => return .{ .r = p, .g = q, .b = hsv_pixel.v },
        4 => return .{ .r = t, .g = p, .b = hsv_pixel.v },
        else => return .{ .r = hsv_pixel.v, .g = p, .b = q },
    }
}

/// Test that `rgbToHsvPixel` and `hsvToRgbPixel` are inverses of each other.
fn _testRgbAndHsvConversion(rgb_pixel: RGBPixel, hsv_pixel: HSVPixel) !void {
    try testHsvApproxEqAbs(
        hsv_pixel,
        rgbToHsvPixel(rgb_pixel),
        1e-4,
    );

    try testRgbApproxEqAbs(
        rgb_pixel,
        hsvToRgbPixel(hsv_pixel),
        1e-4,
    );
}

test "rgbToHsvPixel and hsvToRgbPixel" {
    // Grayscale
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 },
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 0.0 },
    );
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 1.0, .g = 1.0, .b = 1.0 },
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 1.0 },
    );
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 0.5, .g = 0.5, .b = 0.5 },
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 0.5 },
    );

    // 0 degree red
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
        HSVPixel{ .h = 0.0, .s = 1.0, .v = 1.0 },
    );
    // 360 degree red
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 1e-6 },
        HSVPixel{ .h = 1.0 - 1e-6, .s = 1.0, .v = 1.0 },
    );
    // Cyan
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 0.0, .g = 1.0, .b = 1.0 },
        HSVPixel{ .h = 0.5, .s = 1.0, .v = 1.0 },
    );
    // Magenta
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 1.0 },
        HSVPixel{ .h = 0.833333, .s = 1.0, .v = 1.0 },
    );
    // Yellow
    try _testRgbAndHsvConversion(
        RGBPixel{ .r = 1.0, .g = 1.0, .b = 0.0 },
        HSVPixel{ .h = 0.166666, .s = 1.0, .v = 1.0 },
    );

    // Green-ish
    try _testRgbAndHsvConversion(
        RGBPixel.fromHexNumber(0x4ae728),
        HSVPixel{ .h = 0.3036649, .s = 0.8268398, .v = 0.905882 },
    );
    // Blue-ish
    try _testRgbAndHsvConversion(
        RGBPixel.fromHexNumber(0x3d6ea5),
        HSVPixel{ .h = 0.588141, .s = 0.630303, .v = 0.647058 },
    );
}

pub fn rgbToHsvImage(rgb_image: RGBImage, allocator: std.mem.Allocator) HSVImage {
    const output_hsv_pixels = try allocator.alloc(HSVPixel, rgb_image.pixels.len);
    for (output_hsv_pixels, rgb_image.pixels) |*output_hsv_pixel, rgb_pixel| {
        output_hsv_pixel.* = rgbToHsvPixel(rgb_pixel);
    }

    return .{
        .width = rgb_image.width,
        .height = rgb_image.height,
        .pixels = output_hsv_pixels,
    };
}

pub fn hsvToRgbImage(hsv_image: HSVImage, allocator: std.mem.Allocator) RGBImage {
    const output_rgb_pixels = try allocator.alloc(RGBPixel, hsv_image.pixels.len);
    for (output_rgb_pixels, hsv_image.pixels) |*output_rgb_pixel, hsv_pixel| {
        output_rgb_pixel.* = hsvToRgbPixel(hsv_pixel);
    }

    return .{
        .width = hsv_image.width,
        .height = hsv_image.height,
        .pixels = output_rgb_pixels,
    };
}

pub fn hsvPixelInRange(pixel: HSVPixel, lower_bound: HSVPixel, upper_bound: HSVPixel) bool {
    return pixel.h >= lower_bound.h and pixel.h <= upper_bound.h and
        pixel.s >= lower_bound.s and pixel.s <= upper_bound.s and
        pixel.v >= lower_bound.v and pixel.v <= upper_bound.v;
}
