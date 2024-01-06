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
};

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
const h_raw_lower_bound = -1;
const h_raw_upper_bound = 5;
const h_raw_range: comptime_float = h_raw_upper_bound - h_raw_lower_bound;

const h_degree_upper_bound: comptime_float = 360;
const h_degree_scaler: comptime_float = h_degree_upper_bound / h_raw_range;

const h_normalized_upper_bound: comptime_float = 1;
const h_normalized_scaler: comptime_float = h_normalized_upper_bound / h_raw_range;

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

    // Find which color is the max. Ideally, we would use `std.math.approxEqAbs(f32, a,
    // b, 1e-4)` to compare whether floats are equal but this will suffice.
    //
    // Before we scale hue, it is in the range [-1, 5) where:
    // [−1, 1) when the max is R,
    // [1, 3) when the max is G,
    // [3, 5) when the max is B,
    var h_raw: f32 = 0.0;
    if (r >= max) {
        // between yellow & magenta
        h_raw = 0.0 + (g - b) / delta;
    } else if (g >= max) {
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

    // TODO: More tests
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
