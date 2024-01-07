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
    fn fromHexNumber(hex_color: u24) RGBPixel {
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

test "RGBPixel.fromHexNumber" {
    // White
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 1.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0xffffff),
        1e-4,
    );
    // Black
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x000000),
        1e-4,
    );
    // Red
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0xff0000),
        1e-4,
    );
    // Green
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 1.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x00ff00),
        1e-4,
    );
    // Blue
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0x0000ff),
        1e-4,
    );

    // Green-ish
    try testRGBApproxEqAbs(
        RGBPixel{ .r = 0.290196, .g = 0.905882, .b = 0.156862 },
        RGBPixel.fromHexNumber(0x4ae728),
        1e-4,
    );
    // Blue-ish
    try testRGBApproxEqAbs(
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

pub const PixelData = union(enum) {
    rgb: RGBPixel,
    hsv: HSVPixel,
};

pub const ImageData = struct {
    width: u32,
    height: u32,
    pixels: []const PixelData,

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

fn load_image(allocator: std.mem.Allocator) !ImageData {
    const image_file_path = "/home/eric/Downloads/36-1080-export-from-gimp.png";

    var img = try zigimg.Image.fromFilePath(allocator, image_file_path);
    defer img.deinit();

    std.debug.print("\nasdf {} {}", .{
        img.pixels.len(),
    });

    var output_rgb_pixels = allocator.alloc(PixelData, img.pixels.len());
    switch (img.pixels) {
        .rgb24 => |rgb_pixels| {
            for (rgb_pixels, output_rgb_pixels) |pixel, *output_rgb_pixel| {
                output_rgb_pixel.* = pixel.toColorf32();
            }
        },
        else => {
            return error.UnsupportedPixelFormat;
        },
    }

    // img.rawBytes();
    // img.pixels.asBytes()

    return ImageData{
        .width = img.width,
        .height = img.height,
        .pixels = output_rgb_pixels,
    };
}

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

// Based on https://stackoverflow.com/questions/3018313/algorithm-to-convert-rgb-to-hsv-and-hsv-to-rgb-in-range-0-255-for-both/6930407#6930407
// Other notes: https://cs.stackexchange.com/questions/64549/convert-hsv-to-rgb-colors/127918#127918
// Other implementation where I picked up some comment explanations, https://github.com/nitrogenez/prism/blob/9152942425546f6110bd0202d7671d6ff5b25de5/src/spaces/HSV.zig#L9-L40
fn rgb_to_hsv(rgb_pixel: RGBPixel) HSVPixel {
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

fn testRGBApproxEqAbs(expected: RGBPixel, actual: RGBPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
}

fn testHSVApproxEqAbs(expected: HSVPixel, actual: HSVPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.s, actual.s, tolerance);
    try std.testing.expectApproxEqAbs(expected.v, actual.v, tolerance);
}

test "rgb_to_hsv" {
    // Grayscale
    try std.testing.expectEqual(
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 0.0 },
        rgb_to_hsv(RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 }),
    );
    try std.testing.expectEqual(
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 1.0, .g = 1.0, .b = 1.0 }),
    );
    try std.testing.expectEqual(
        HSVPixel{ .h = 0.0, .s = 0.0, .v = 0.5 },
        rgb_to_hsv(RGBPixel{ .r = 0.5, .g = 0.5, .b = 0.5 }),
    );

    // 0 degree red
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.0, .s = 1.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 }),
        1e-4,
    );
    // 360 degree red
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 1.0, .s = 1.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 1.0, .g = 0.0, .b = 1e-4 }),
        1e-4,
    );
    // Cyan
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.5, .s = 1.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 0.0, .g = 1.0, .b = 1.0 }),
        1e-4,
    );
    // Magenta
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.833333, .s = 1.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 1.0, .g = 0.0, .b = 1.0 }),
        1e-4,
    );
    // Yellow
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.166666, .s = 1.0, .v = 1.0 },
        rgb_to_hsv(RGBPixel{ .r = 1.0, .g = 1.0, .b = 0.0 }),
        1e-4,
    );

    // Green-ish
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.3036649, .s = 0.8268398, .v = 0.905882 },
        rgb_to_hsv(RGBPixel.fromHexNumber(0x4ae728)),
        1e-4,
    );
    // Blue-ish
    try testHSVApproxEqAbs(
        HSVPixel{ .h = 0.588141, .s = 0.630303, .v = 0.647058 },
        rgb_to_hsv(RGBPixel.fromHexNumber(0x3d6ea5)),
        1e-4,
    );
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
    _ = try load_image(allocator);
}
