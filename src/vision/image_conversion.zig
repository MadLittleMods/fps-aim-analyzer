const std = @import("std");
const zigimg = @import("zigimg");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const comptime_assert = assertions.comptime_assert;
const approxEqAbs = assertions.approxEqAbs;

/// All values are in the range [0, 1]
pub const RGBPixel = struct {
    r: f32,
    g: f32,
    b: f32,

    // We can do some extra checks for hard-coded values during compilation but let's
    // avoid the overhead if someone is creating a pixel dynamically.
    pub fn init(comptime r: f32, comptime g: f32, comptime b: f32) @This() {
        if (r < 0.0 or r > 1.0) {
            @compileLog("r=", r);
            @compileError("When creating an RGBPixel, r must be in the range [0, 1]");
        }
        if (g < 0.0 or g > 1.0) {
            @compileLog("g=", g);
            @compileError("When creating an RGBPixel, g must be in the range [0, 1]");
        }
        if (b < 0.0 or b > 1.0) {
            @compileLog("b=", b);
            @compileError("When creating an RGBPixel, b must be in the range [0, 1]");
        }

        return .{
            .r = r,
            .g = g,
            .b = b,
        };
    }

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

test "RGBPixel.fromHexNumber" {
    // White
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 1.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0xffffff),
        1e-4,
    );
    // Black
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x000000),
        1e-4,
    );
    // Red
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 1.0, .g = 0.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0xff0000),
        1e-4,
    );
    // Green
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 1.0, .b = 0.0 },
        RGBPixel.fromHexNumber(0x00ff00),
        1e-4,
    );
    // Blue
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 0.0, .g = 0.0, .b = 1.0 },
        RGBPixel.fromHexNumber(0x0000ff),
        1e-4,
    );

    // Green-ish
    try _testRgbApproxEqAbs(
        RGBPixel{ .r = 0.290196, .g = 0.905882, .b = 0.156862 },
        RGBPixel.fromHexNumber(0x4ae728),
        1e-4,
    );
    // Blue-ish
    try _testRgbApproxEqAbs(
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

    // We can do some extra checks for hard-coded values during compilation but let's
    // avoid the overhead if someone is creating a pixel dynamically.
    pub fn init(comptime h: f32, comptime s: f32, comptime v: f32) @This() {
        if (h < 0.0 or h > 1.0) {
            @compileLog("h=", h);
            @compileError("When creating an HSVPixel, h must be in the range [0, 1]");
        }
        if (s < 0.0 or s > 1.0) {
            @compileLog("s=", s);
            @compileError("When creating an HSVPixel, s must be in the range [0, 1]");
        }
        if (v < 0.0 or v > 1.0) {
            @compileLog("v=", v);
            @compileError("When creating an HSVPixel, v must be in the range [0, 1]");
        }

        return .{
            .h = h,
            .s = s,
            .v = v,
        };
    }
};

pub const GrayscalePixel = struct {
    value: f32,
};

pub const BinaryPixel = struct {
    value: bool,
};

fn _testRgbApproxEqAbs(expected: RGBPixel, actual: RGBPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.r, actual.r, tolerance);
    try std.testing.expectApproxEqAbs(expected.g, actual.g, tolerance);
    try std.testing.expectApproxEqAbs(expected.b, actual.b, tolerance);
}

fn _testHsvApproxEqAbs(expected: HSVPixel, actual: HSVPixel, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.s, actual.s, tolerance);
    try std.testing.expectApproxEqAbs(expected.v, actual.v, tolerance);
}

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
            .rgba32 => |rgb_pixels| {
                for (rgb_pixels, output_rgb_pixels, 0..) |pixel, *output_rgb_pixel, pixel_index| {
                    const zigimg_color_f32 = pixel.toColorf32();
                    // As long as the image isn't transparent, we can just ignore the
                    // alpha and carry on like normal.
                    if (zigimg_color_f32.a != 1.0) {
                        std.log.err("Image contains transparent pixel at {} which we don't support {}", .{
                            pixel_index,
                            zigimg_color_f32,
                        });
                        return error.UnsupportedPixelTransparency;
                    }
                    output_rgb_pixel.* = RGBPixel{
                        .r = zigimg_color_f32.r,
                        .g = zigimg_color_f32.g,
                        .b = zigimg_color_f32.b,
                    };
                }
            },
            inline else => |pixels, tag| {
                _ = pixels;
                std.log.err("Unsupported pixel format: {s}", .{@tagName(tag)});
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
                .r = @as(u8, @as(u8, @intFromFloat(pixel.r * 255.0))),
                .g = @as(u8, @as(u8, @intFromFloat(pixel.g * 255.0))),
                .b = @as(u8, @as(u8, @intFromFloat(pixel.b * 255.0))),
            };
        }

        try img.writeToFilePath(image_file_path, .{ .png = .{} });
    }
};

pub const HSVImage = struct {
    width: usize,
    height: usize,
    /// Row-major order (line by line)
    pixels: []const HSVPixel,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn saveImageToFilePath(self: *const @This(), image_file_path: []const u8, allocator: std.mem.Allocator) !void {
        const rgb_image = try hsvToRgbImage(self.*, allocator);
        defer rgb_image.deinit(allocator);

        try rgb_image.saveImageToFilePath(
            image_file_path,
            allocator,
        );
    }
};

pub const GrayscaleImage = struct {
    width: usize,
    height: usize,
    /// Row-major order (line by line)
    pixels: []const GrayscalePixel,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const BinaryImage = struct {
    width: usize,
    height: usize,
    /// Row-major order (line by line)
    pixels: []const BinaryPixel,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn cropImage(
    image: anytype,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    const PixelType = @TypeOf(image.pixels[0]);
    var output_pixels = try allocator.alloc(PixelType, width * height);
    for (0..height) |crop_y| {
        for (0..width) |crop_x| {
            const src_x = x + crop_x;
            const src_y = y + crop_y;
            output_pixels[crop_y * width + crop_x] = image.pixels[src_y * image.width + src_x];
        }
    }

    return .{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

pub fn maskImage(
    image: anytype,
    mask: BinaryImage,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    assert(image.width == mask.width, "maskImage: Image and mask width should match but saw {} != {}", .{
        image.width,
        mask.width,
    });
    assert(image.height == mask.height, "maskImage: Image and mask height should match but saw {} != {}", .{
        image.height,
        mask.height,
    });

    const PixelType = @TypeOf(image.pixels[0]);
    const output_pixels = try allocator.alloc(PixelType, image.pixels.len);
    switch (PixelType) {
        RGBPixel => @memset(output_pixels, RGBPixel{ .r = 0.0, .g = 0.0, .b = 0.0 }),
        HSVPixel => @memset(output_pixels, RGBPixel{ .h = 0.0, .s = 0.0, .v = 0.0 }),
        GrayscalePixel => @memset(output_pixels, RGBPixel{ .value = 0.0 }),
        BinaryPixel => @memset(output_pixels, RGBPixel{ .value = false }),
        else => {
            @compileLog("PixelType=", @typeName(PixelType));
            @compileError("maskImage: Unsupported pixel type");
        },
    }

    for (0..mask.height) |y| {
        const row_start_pixel_index = y * mask.width;
        for (0..mask.width) |x| {
            const current_pixel_index = row_start_pixel_index + x;
            if (mask.pixels[current_pixel_index].value) {
                output_pixels[current_pixel_index] = image.pixels[current_pixel_index];
            }
        }
    }

    return .{
        .width = image.width,
        .height = image.height,
        .pixels = output_pixels,
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

    // [0, 6]
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
    try _testHsvApproxEqAbs(
        hsv_pixel,
        rgbToHsvPixel(rgb_pixel),
        1e-4,
    );

    try _testRgbApproxEqAbs(
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

pub fn rgbToHsvImage(rgb_image: RGBImage, allocator: std.mem.Allocator) !HSVImage {
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

pub fn hsvToRgbImage(hsv_image: HSVImage, allocator: std.mem.Allocator) !RGBImage {
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

pub fn hsvToBinaryImage(hsv_image: HSVImage, allocator: std.mem.Allocator) !BinaryImage {
    const output_binary_pixels = try allocator.alloc(BinaryPixel, hsv_image.pixels.len);
    for (output_binary_pixels, hsv_image.pixels) |*output_binary_pixel, hsv_pixel| {
        output_binary_pixel.* = BinaryPixel{
            .value = hsv_pixel.v > 0.0,
        };
    }

    return .{
        .width = hsv_image.width,
        .height = hsv_image.height,
        .pixels = output_binary_pixels,
    };
}

pub fn binaryToRgbImage(binary_image: BinaryImage, allocator: std.mem.Allocator) !RGBImage {
    const output_rgb_pixels = try allocator.alloc(RGBPixel, binary_image.pixels.len);
    for (output_rgb_pixels, binary_image.pixels) |*output_rgb_pixel, binary_pixel| {
        output_rgb_pixel.* = RGBPixel{
            .r = if (binary_pixel.value) 1.0 else 0.0,
            .g = if (binary_pixel.value) 1.0 else 0.0,
            .b = if (binary_pixel.value) 1.0 else 0.0,
        };
    }

    return .{
        .width = binary_image.width,
        .height = binary_image.height,
        .pixels = output_rgb_pixels,
    };
}

pub fn hsvPixelInRange(pixel: HSVPixel, lower_bound: HSVPixel, upper_bound: HSVPixel) bool {
    return pixel.h >= lower_bound.h and pixel.h <= upper_bound.h and
        pixel.s >= lower_bound.s and pixel.s <= upper_bound.s and
        pixel.v >= lower_bound.v and pixel.v <= upper_bound.v;
}

test "hsvPixelInRange" {
    try std.testing.expect(hsvPixelInRange(
        HSVPixel{ .h = 6.60075366e-01, .s = 7.25409865e-01, .v = 9.56862747e-01 },
        // OpenCV: (90, 34, 214)
        HSVPixel.init(0.5, 0.133333, 0.839215),
        // OpenCV: (152, 255, 255)
        HSVPixel.init(0.844444, 1.0, 1.0),
    ));
}
