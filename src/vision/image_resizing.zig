const std = @import("std");
const image_conversion = @import("image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const RGBPixel = image_conversion.RGBPixel;
const HSVPixel = image_conversion.HSVPixel;
const GrayscalePixel = image_conversion.GrayscalePixel;
const BinaryPixel = image_conversion.BinaryPixel;
const getPixelClamped = image_conversion.getPixelClamped;
const getPixelValueFieldNames = image_conversion.getPixelValueFieldNames;
const rgbPixelsfromHexArray = image_conversion.rgbPixelsfromHexArray;
const expectImageApproxEqual = image_conversion.expectImageApproxEqual;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

/// Sampling methods to use when resizing an image
const InterpolationMethod = enum {
    nearest,
    box,
    bilinear,
    bicubic,
};

/// Nearest neighbor sampling: Sample the nearest pixel to the given uv coordinate.
pub fn sampleNearest(source_image: anytype, u: f32, v: f32) std.meta.Child(@TypeOf(source_image.pixels)) {
    const x: isize = @intFromFloat(u * @as(f32, @floatFromInt(source_image.width)));
    const y: isize = @intFromFloat(v * @as(f32, @floatFromInt(source_image.height)));

    return getPixelClamped(source_image, x, y);
    // return source_image.pixels[y * source_image.width + x];
}

// Average all pixels in the UV region [u - u_min,  u + u_min] and [v - v_min,  v + v_min]
pub fn sampleBox(source_image: anytype, u: f32, v: f32, u_min: f32, v_min: f32) std.meta.Child(@TypeOf(source_image.pixels)) {
    const x_min = ((u - u_min) * @as(f32, @floatFromInt(source_image.width)));
    const x_max = ((u + u_min) * @as(f32, @floatFromInt(source_image.width)));
    const y_min = ((v - v_min) * @as(f32, @floatFromInt(source_image.height)));
    const y_max = ((v + v_min) * @as(f32, @floatFromInt(source_image.height)));

    const x_min_int: isize = @intFromFloat(x_min);
    const x_max_int: isize = @intFromFloat(@ceil(x_max));
    const y_min_int: isize = @intFromFloat(y_min);
    const y_max_int: isize = @intFromFloat(@ceil(y_max));

    const PixelType = std.meta.Child(@TypeOf(source_image.pixels));
    var resultant_pixel: PixelType = undefined;
    inline for (comptime getPixelValueFieldNames(PixelType)) |pixel_value_field_name| {
        // Rename it to something shorter so all of these lookups fit better
        const f = pixel_value_field_name;

        var sum: f32 = 0.0;
        var total_area: f32 = 0.0;
        for (@intCast(y_min_int)..@intCast(y_max_int)) |y_int| {
            for (@intCast(x_min_int)..@intCast(x_max_int)) |x_int| {
                const x = @as(f32, @floatFromInt(x_int));
                const y = @as(f32, @floatFromInt(y_int));

                if (u < 0.25 and v < 0.25) {
                    std.debug.print("\n\tx: {} < {} > {}", .{ x_min, x, x_max });
                    std.debug.print("\n\ty: {} < {} > {}", .{ y_min, y, y_max });
                }

                var x_portion: f32 = 1.0;
                if (x < x_min) {
                    x_portion = @fabs(x - x_min);
                } else if (x > x_max) {
                    x_portion = @fabs(x - x_max);
                }

                var y_portion: f32 = 1.0;
                if (y < y_min) {
                    y_portion = @fabs(y - y_min);
                } else if (y > y_max) {
                    y_portion = @fabs(y - y_max);
                }

                const pixel = getPixelClamped(source_image, @intCast(x_int), @intCast(y_int));
                const area = x_portion * y_portion;
                if (u < 0.25 and v < 0.25) {
                    std.debug.print("\n\t{s} value={} area={}", .{ f, @field(pixel, f), area });
                }
                sum += @field(pixel, f) * area;
                total_area += area;
            }
        }

        const result = sum / total_area;
        if (u < 0.25 and v < 0.25) {
            std.debug.print("\nresult for {s}: {} <- {} / {}", .{ f, result, sum, total_area });
        }
        @field(resultant_pixel, f) = result;
    }

    return resultant_pixel;
}

/// Linear interpolate between two values.
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// Bilinear interpolate between four values.
fn bilerp(p00: f32, p10: f32, p01: f32, p11: f32, x_fractional: f32, y_fractional: f32) f32 {
    // p00 ----🔵---- p10
    //         |
    //         |
    //         |
    // p01 ----🟠---- p11
    //
    // Interpolate between the first set of values in the x-direction to find the blue dot
    const x1 = lerp(p00, p10, x_fractional);
    // Interpolate between the second set of values in the x-direction to find the orange dot
    const x2 = lerp(p01, p11, x_fractional);

    // Interpolate between the two new intermediate values in the y-direction to find the green dot
    //
    // p00 ----x1---- p10
    //         |
    //         🟢
    //         |
    // p01 ----x2---- p11
    const result = lerp(x1, x2, y_fractional);
    return result;
}

// Reference:
//  - https://blog.demofox.org/2015/08/15/resizing-images-with-bicubic-interpolation/
//  - https://en.wikipedia.org/wiki/Bilinear_interpolation
//  - https://bartwronski.com/2021/02/15/bilinear-down-upsampling-pixel-grids-and-that-half-pixel-offset/
pub fn sampleBilinear(source_image: anytype, u: f32, v: f32) std.meta.Child(@TypeOf(source_image.pixels)) {
    // Calculate pixel center coordinates in the source image. Offset by half a pixel so
    // that we are measuring to/from the center of a pixel which can then can be rounded
    // back down to the pixel coordinate. This allows sampling to occur evenly around a
    // pixel position and integer truncation works correctly around the edges/corners.
    const x = (u * @as(f32, @floatFromInt(source_image.width))) - 0.5;
    const x_fractional = x - @floor(x);
    const y = (v * @as(f32, @floatFromInt(source_image.height))) - 0.5;
    const y_fractional = y - @floor(y);

    const p00 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y + 0));
    const p10 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y + 0));
    const p01 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y + 1));
    const p11 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y + 1));

    // Interpolate bi-linearly!
    const PixelType = std.meta.Child(@TypeOf(source_image.pixels));
    switch (PixelType) {
        RGBPixel => {
            return .{
                .r = bilerp(p00.r, p10.r, p01.r, p11.r, x_fractional, y_fractional),
                .g = bilerp(p00.g, p10.g, p01.g, p11.g, x_fractional, y_fractional),
                .b = bilerp(p00.b, p10.b, p01.b, p11.b, x_fractional, y_fractional),
            };
        },
        HSVPixel => {
            return .{
                .h = bilerp(p00.h, p10.h, p01.h, p11.h, x_fractional, y_fractional),
                .s = bilerp(p00.s, p10.s, p01.s, p11.s, x_fractional, y_fractional),
                .v = bilerp(p00.v, p10.v, p01.v, p11.v, x_fractional, y_fractional),
            };
        },
        GrayscalePixel => {
            return .{
                .value = bilerp(p00.value, p10.value, p01.value, p11.value, x_fractional, y_fractional),
            };
        },
        BinaryPixel => {
            @compileError("sampleBilinear(...): BinaryPixel is not supported since we can't interpolate between true/false");
        },
        else => {
            @compileLog("PixelType=", @typeName(PixelType));
            @compileError("sampleBilinear(...): Unsupported pixel type");
        },
    }
}

fn cubicHermiteInterpolation(A: f32, B: f32, C: f32, D: f32, t: f32) f32 {
    const a = -A / 2.0 + (3.0 * B) / 2.0 - (3.0 * C) / 2.0 + D / 2.0;
    const b = A - (5.0 * B) / 2.0 + 2.0 * C - D / 2.0;
    const c = -A / 2.0 + C / 2.0;
    const d = B;

    return a * t * t * t + b * t * t + c * t + d;
}

/// Hermite Bicubic interpolation
///
// Reference:
//  - https://blog.demofox.org/2015/08/15/resizing-images-with-bicubic-interpolation/
//  - Bicubic Interpolation - Computerphile, https://www.youtube.com/watch?v=poY_nGzEEWM
//  - https://en.wikipedia.org/wiki/Bicubic_interpolation
pub fn sampleBicubic(source_image: anytype, u: f32, v: f32) std.meta.Child(@TypeOf(source_image.pixels)) {
    // Calculate coordinates. We also need to offset by half a pixel to keep image from
    // shifting down and left half a pixel.
    const x = (u * @as(f32, @floatFromInt(source_image.width))) - 0.5;
    const x_int: isize = @intFromFloat(x);
    _ = x_int;
    const x_fractional = x - @floor(x);

    const y = (v * @as(f32, @floatFromInt(source_image.height))) - 0.5;
    const y_int: isize = @intFromFloat(y);
    _ = y_int;
    const y_fractional = y - @floor(y);

    // Get the surrounding 16 pixels
    //
    // 1st row
    const p00 = getPixelClamped(source_image, @intFromFloat(x - 1), @intFromFloat(y - 1));
    const p10 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y - 1));
    const p20 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y - 1));
    const p30 = getPixelClamped(source_image, @intFromFloat(x + 2), @intFromFloat(y - 1));
    // 2nd row
    const p01 = getPixelClamped(source_image, @intFromFloat(x - 1), @intFromFloat(y + 0));
    const p11 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y + 0));
    const p21 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y + 0));
    const p31 = getPixelClamped(source_image, @intFromFloat(x + 2), @intFromFloat(y + 0));
    // 3rd row
    const p02 = getPixelClamped(source_image, @intFromFloat(x - 1), @intFromFloat(y + 1));
    const p12 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y + 1));
    const p22 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y + 1));
    const p32 = getPixelClamped(source_image, @intFromFloat(x + 2), @intFromFloat(y + 1));
    // 4th row
    const p03 = getPixelClamped(source_image, @intFromFloat(x - 1), @intFromFloat(y + 2));
    const p13 = getPixelClamped(source_image, @intFromFloat(x + 0), @intFromFloat(y + 2));
    const p23 = getPixelClamped(source_image, @intFromFloat(x + 1), @intFromFloat(y + 2));
    const p33 = getPixelClamped(source_image, @intFromFloat(x + 2), @intFromFloat(y + 2));

    const PixelType = std.meta.Child(@TypeOf(source_image.pixels));
    var resultant_pixel: PixelType = undefined;
    inline for (comptime getPixelValueFieldNames(PixelType)) |pixel_value_field_name| {
        // Rename it to something shorter so all of these lookups fit better
        const f = pixel_value_field_name;

        const x1 = cubicHermiteInterpolation(@field(p00, f), @field(p10, f), @field(p20, f), @field(p30, f), x_fractional);
        const x2 = cubicHermiteInterpolation(@field(p01, f), @field(p11, f), @field(p21, f), @field(p31, f), x_fractional);
        const x3 = cubicHermiteInterpolation(@field(p02, f), @field(p12, f), @field(p22, f), @field(p32, f), x_fractional);
        const x4 = cubicHermiteInterpolation(@field(p03, f), @field(p13, f), @field(p23, f), @field(p33, f), x_fractional);
        const result = cubicHermiteInterpolation(x1, x2, x3, x4, y_fractional);

        // We need to clamp because the cubic hermite curves under/overshoot the values
        @field(resultant_pixel, f) = std.math.clamp(result, 0.0, 1.0);
    }

    return resultant_pixel;
}

/// Pretty much an "auto" interpolation method.
pub fn getIdealInterpolationMethod(
    image: anytype,
    new_width: usize,
    new_height: usize,
) InterpolationMethod {
    // If the image can be perfectly resized using nearest neighbor, then use that.
    if (image.width % new_width == 0 and image.height % new_height == 0) {
        return .nearest;
    }

    // > When making an image larger, use bilinear, which has a natural smoothing
    // > effect. You want to blend over the interpolated fake detail in the new, larger
    // > image that never existed in the original image.
    // >
    // > -- https://blog.codinghorror.com/better-image-resizing/
    if (new_width > image.width or new_height > image.height) {
        return .bilinear;
    }

    // > When making an image smaller, use bicubic, which has a natural sharpening
    // > effect. You want to emphasize the data that remains in the new, smaller image
    // > after discarding all that extra detail from the original image
    // >
    // > -- https://blog.codinghorror.com/better-image-resizing/
    // return .bicubic;
    //
    // But instead, we will use box sampling since it takes all pixels into account and
    // produce a more accurate result
    return .box;
}

// Reference: https://blog.demofox.org/2015/08/15/resizing-images-with-bicubic-interpolation/
pub fn resizeImage(
    image: anytype,
    new_width: usize,
    new_height: usize,
    /// Sample type to use when resizing
    interpolation_method: InterpolationMethod,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    const PixelType = std.meta.Child(@TypeOf(image.pixels));
    var output_pixels = try allocator.alloc(PixelType, new_width * new_height);

    const u_min = (0 + 0.5) / @as(f32, @floatFromInt(new_height));
    const v_min = (0 + 0.5) / @as(f32, @floatFromInt(new_width));

    for (0..new_height) |y| {
        const row_start_pixel_index = y * new_width;

        // Calculate UV offset to the center of the pixel (this way when we sample the
        // image, we get a proper average)
        //
        // > This translates [pixel coordinates] to UVs, or "normalized" coordinates
        // > e.g. [0.5/4, 1.5/4, 2.5/4, 3.5/4], which spans a range of [0.5/width, 1 –
        // > 0.5/width] (pixel centers).
        // >
        // > This representation seems counterintuitive at first, but what it provides
        // > us is a guarantee and convention that the image corners are placed at [0
        // > and 1] normalized, or [0, width] unnormalized.
        // >
        // > -- https://bartwronski.com/2021/02/15/bilinear-down-upsampling-pixel-grids-and-that-half-pixel-offset/
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(new_height));
        for (0..new_width) |x| {
            const current_pixel_index = row_start_pixel_index + x;
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(new_width));

            if (u < 0.25 and v < 0.25) {
                std.debug.print("\nx={} y={}", .{ x, y });
            }

            output_pixels[current_pixel_index] = switch (interpolation_method) {
                .nearest => sampleNearest(image, u, v),
                .box => sampleBox(image, u, v, u_min, v_min),
                .bilinear => sampleBilinear(image, u, v),
                .bicubic => sampleBicubic(image, u, v),
            };
        }
    }

    return .{
        .width = new_width,
        .height = new_height,
        .pixels = output_pixels,
    };
}

const mooshroom_image = RGBImage{
    .width = 8,
    .height = 8,
    .pixels = &rgbPixelsfromHexArray(&[_]u24{
        // 8x8 cow art via https://www.reddit.com/r/PixelArt/comments/103bznv/just_started_my_pixel_art_journey_i_heard_it_was/
        // 0xdbc9b4, 0x000000, 0x000000, 0xdbc9b4, 0x000000, 0x000000, 0x000000, 0x000000,
        // 0x000000, 0xfcecd1, 0xfcecd1, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000,
        // 0x000000, 0xfcecd1, 0xfcecd1, 0x2d1e2f, 0xfcecd1, 0xfcecd1, 0xfcecd1, 0x2d1e2f,
        // 0xc3a79c, 0xdbc9b4, 0xc3a79c, 0xfcecd1, 0xfcecd1, 0x2d1e2f, 0xfcecd1, 0xfcecd1,
        // 0xdbc9b4, 0xdbc9b4, 0xdbc9b4, 0xfcecd1, 0x2d1e2f, 0x2d1e2f, 0xfcecd1, 0xfcecd1,
        // 0x000000, 0xfcecd1, 0xfcecd1, 0xfcecd1, 0xfcecd1, 0xfcecd1, 0xfcecd1, 0xfcecd1,
        // 0x000000, 0xfcecd1, 0x000000, 0xfcecd1, 0x000000, 0xdbc9b4, 0x000000, 0xfcecd1,
        // 0x000000, 0xc3a79c, 0x000000, 0xc3a79c, 0x000000, 0x9c807e, 0x000000, 0xc3a79c,

        // 8x8 mooshroom variation (color differences are easier to see)
        0x940c0f, 0xffffff, 0xffffff, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
        0xffffff, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
        0xffffff, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3,
        0x171414, 0xd39696, 0x171414, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xa80e12, 0xa80e12,
        0xce9191, 0xd39696, 0xce9191, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12,
        0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
        0xffffff, 0xa80e12, 0xffffff, 0xa80e12, 0xffffff, 0x940c0f, 0xd39696, 0xa80e12,
        0xffffff, 0x171414, 0xffffff, 0x171414, 0xffffff, 0x333333, 0xffffff, 0x171414,
    }),
};

// 16x16 test image via https://medium.com/hackernoon/how-tensorflows-tf-image-resize-stole-60-days-of-my-life-aba5eb093f35
const test_square_image = RGBImage{
    .width = 16,
    .height = 16,
    .pixels = &rgbPixelsfromHexArray(
        &([_]u24{0x010ab9} ** 16 ++
            [_]u24{ 0x03a3de, 0xe91b51 } ++ [_]u24{0xde03a8} ** 12 ++ [_]u24{ 0xe91b51, 0x03a3de } ++
            ([_]u24{ 0x2d1903, 0xe91b51, 0x1be951 } ++ [_]u24{0xffffff} ** 10 ++ [_]u24{ 0x1be951, 0xe91b51, 0x2d1903 }) ** 12 ++
            [_]u24{ 0x03a3de, 0xe91b51 } ++ [_]u24{0xde03a8} ** 12 ++ [_]u24{ 0xe91b51, 0x03a3de } ++
            [_]u24{0x010ab9} ** 16),
    ),
};

// 4x4 test checkerboard image
const test_color_checkerboard_image = RGBImage{
    .width = 4,
    .height = 4,
    .pixels = &rgbPixelsfromHexArray(&.{
        0xff0000, 0x00ff00, 0xff0000, 0x0000ff,
        0x00ff00, 0xff0000, 0x0000ff, 0xff0000,
        0x0000ff, 0x00ff00, 0xff0000, 0xffffff,
        0x00ff00, 0x0000ff, 0xffffff, 0xff0000,
    }),
};

// When comparing float pixels, they should be less than an 8-bit increment value apart
// which means there will be no difference when we convert back to 8-bit (255) based
// values since everything is floored.
const PIXEL_TOLERANCE = 1.0 / 255.0;

const ResizeTestCase = struct {
    label: []const u8,
    source_image: RGBImage,
    new_width: usize,
    new_height: usize,
    expected_pixels: []const RGBPixel,
};

fn _test_resize_method(test_case: ResizeTestCase, interpolation_method: InterpolationMethod, allocator: std.mem.Allocator) !void {
    const resized_image = try resizeImage(
        test_case.source_image,
        test_case.new_width,
        test_case.new_height,
        interpolation_method,
        allocator,
    );
    defer resized_image.deinit(allocator);

    try expectImageApproxEqual(
        resized_image,
        RGBImage{
            .width = test_case.new_width,
            .height = test_case.new_height,
            .pixels = test_case.expected_pixels,
        },
        PIXEL_TOLERANCE,
        allocator,
    );
}

fn test_resize_method(test_case: ResizeTestCase, interpolation_method: InterpolationMethod, allocator: std.mem.Allocator) !void {
    _test_resize_method(test_case, interpolation_method, allocator) catch |err| {
        std.debug.print("\nTest case: {s} ({}x{} to {}x{}) (using {}):", .{
            test_case.label,
            test_case.source_image.width,
            test_case.source_image.height,
            test_case.new_width,
            test_case.new_height,
            interpolation_method,
        });

        try printLabeledImage("Source image", test_case.source_image, .full_block, allocator);

        return err;
    };
}

test "resizeImage .nearest" {
    const allocator = std.testing.allocator;

    const test_cases = [_]ResizeTestCase{
        .{
            .label = "Upscale mooshroom_image uniformly",
            .source_image = mooshroom_image,
            .new_width = 24,
            .new_height = 24,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3,
                0x171414, 0x171414, 0x171414, 0xd39696, 0xd39696, 0xd39696, 0x171414, 0x171414, 0x171414, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0x171414, 0x171414, 0x171414, 0xd39696, 0xd39696, 0xd39696, 0x171414, 0x171414, 0x171414, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0x171414, 0x171414, 0x171414, 0xd39696, 0xd39696, 0xd39696, 0x171414, 0x171414, 0x171414, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xce9191, 0xce9191, 0xce9191, 0xd39696, 0xd39696, 0xd39696, 0xce9191, 0xce9191, 0xce9191, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xce9191, 0xce9191, 0xce9191, 0xd39696, 0xd39696, 0xd39696, 0xce9191, 0xce9191, 0xce9191, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xce9191, 0xce9191, 0xce9191, 0xd39696, 0xd39696, 0xd39696, 0xce9191, 0xce9191, 0xce9191, 0xa80e12, 0xa80e12, 0xa80e12, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xb3b3b3, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xd39696, 0xd39696, 0xd39696, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xd39696, 0xd39696, 0xd39696, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0xa80e12, 0xa80e12, 0xa80e12, 0xffffff, 0xffffff, 0xffffff, 0x940c0f, 0x940c0f, 0x940c0f, 0xd39696, 0xd39696, 0xd39696, 0xa80e12, 0xa80e12, 0xa80e12,
                0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x333333, 0x333333, 0x333333, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414,
                0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x333333, 0x333333, 0x333333, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414,
                0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414, 0xffffff, 0xffffff, 0xffffff, 0x333333, 0x333333, 0x333333, 0xffffff, 0xffffff, 0xffffff, 0x171414, 0x171414, 0x171414,
            }),
        },
        .{
            .label = "Upscale test_color_checkerboard_image uniformly",
            .source_image = test_color_checkerboard_image,
            .new_width = 8,
            .new_height = 8,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0xff0000, 0xff0000, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff,
                0xff0000, 0xff0000, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff,
                0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff, 0xff0000, 0xff0000,
                0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff, 0xff0000, 0xff0000,
                0x0000ff, 0x0000ff, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0xffffff, 0xffffff,
                0x0000ff, 0x0000ff, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0xffffff, 0xffffff,
                0x00ff00, 0x00ff00, 0x0000ff, 0x0000ff, 0xffffff, 0xffffff, 0xff0000, 0xff0000,
                0x00ff00, 0x00ff00, 0x0000ff, 0x0000ff, 0xffffff, 0xffffff, 0xff0000, 0xff0000,
            }),
        },
        .{
            .label = "Downscale test_square_image uniformly",
            .source_image = test_square_image,
            .new_width = 4,
            .new_height = 4,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0x1be951, 0xffffff, 0xffffff, 0xe91b51,
                0x1be951, 0xffffff, 0xffffff, 0xe91b51,
                0x1be951, 0xffffff, 0xffffff, 0xe91b51,
                0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51,
            }),
        },
        .{
            .label = "Downscale test_square_image (non-evenly divisible)",
            .source_image = test_square_image,
            .new_width = 7,
            .new_height = 7,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51,
                0xe91b51, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xe91b51,
                0xe91b51, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xe91b51,
                0xe91b51, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xe91b51,
                0xe91b51, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xe91b51,
                0xe91b51, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xe91b51,
                0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51,
            }),
        },
        .{
            .label = "Upscale test_square_image (non-evenly divisible)",
            .source_image = test_square_image,
            .new_width = 23,
            .new_height = 23,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9,
                0x03a3de, 0xe91b51, 0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51, 0xe91b51, 0x03a3de,
                0x03a3de, 0xe91b51, 0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51, 0xe91b51, 0x03a3de,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x2d1903, 0xe91b51, 0xe91b51, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0xe91b51, 0xe91b51, 0x2d1903,
                0x03a3de, 0xe91b51, 0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51, 0xe91b51, 0x03a3de,
                0x03a3de, 0xe91b51, 0xe91b51, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xe91b51, 0xe91b51, 0x03a3de,
                0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9, 0x010ab9,
            }),
        },
        .{
            .label = "Downscale test_square_image (non-uniform and non-evenly divisible)",
            .source_image = test_square_image,
            .new_width = 9,
            .new_height = 6,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                0x03a3de, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0x03a3de,
                0x2d1903, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0x2d1903,
                0x2d1903, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0x2d1903,
                0x2d1903, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0x2d1903,
                0x2d1903, 0x1be951, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0xffffff, 0x1be951, 0x2d1903,
                0x03a3de, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0xde03a8, 0x03a3de,
            }),
        },
    };

    for (test_cases) |test_case| {
        try test_resize_method(test_case, .nearest, allocator);
    }
}

test "resizeImage .box" {
    const allocator = std.testing.allocator;

    const test_cases = [_]ResizeTestCase{
        // .{
        //     .label = "Downscale test_square_image (uniformly)",
        //     .source_image = test_square_image,
        //     .new_width = 4,
        //     .new_height = 4,
        //     .expected_pixels = &rgbPixelsfromHexArray(&.{
        //         // (matches Serenity/Chrome)
        //         0x70528a, 0xb782d7, 0xb782d7, 0x70528a,
        //         0x8b8668, 0xffffff, 0xffffff, 0x8c8768,
        //         0x8b8668, 0xffffff, 0xffffff, 0x8c8768,
        //         0x70528a, 0xb782d7, 0xb782d7, 0x70528a,
        //     }),
        // },
        .{
            .label = "Upscale mooshroom_image uniformly",
            .source_image = mooshroom_image,
            .new_width = 24,
            .new_height = 24,
            .expected_pixels = &rgbPixelsfromHexArray(&.{
                // ...
            }),
        },
        // .{
        //     .label = "Upscale test_color_checkerboard_image uniformly",
        //     .source_image = test_color_checkerboard_image,
        //     .new_width = 8,
        //     .new_height = 8,
        //     .expected_pixels = &rgbPixelsfromHexArray(&.{
        //         0xff0000, 0xff0000, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff,
        //         0xff0000, 0xff0000, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff,
        //         0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff, 0xff0000, 0xff0000,
        //         0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0x0000ff, 0x0000ff, 0xff0000, 0xff0000,
        //         0x0000ff, 0x0000ff, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0xffffff, 0xffffff,
        //         0x0000ff, 0x0000ff, 0x00ff00, 0x00ff00, 0xff0000, 0xff0000, 0xffffff, 0xffffff,
        //         0x00ff00, 0x00ff00, 0x0000ff, 0x0000ff, 0xffffff, 0xffffff, 0xff0000, 0xff0000,
        //         0x00ff00, 0x00ff00, 0x0000ff, 0x0000ff, 0xffffff, 0xffffff, 0xff0000, 0xff0000,
        //     }),
        // },
    };

    for (test_cases) |test_case| {
        try test_resize_method(test_case, .box, allocator);
    }
}

test "resizeImage" {
    const allocator = std.testing.allocator;

    // const nearest_resized_image = try resizeImage(image, 24, 24, .nearest, allocator);
    // defer nearest_resized_image.deinit(allocator);

    // const bilinear_resized_image = try resizeImage(image, 32, 32, .bilinear, allocator);
    // defer bilinear_resized_image.deinit(allocator);

    // const bicubic_resized_image = try resizeImage(image, 32, 32, .bicubic, allocator);
    // defer bicubic_resized_image.deinit(allocator);

    // try printLabeledImage("Original (8x8)", image, .half_block, allocator);
    // try printLabeledImage("Nearest-neighbor resized (24x24)", nearest_resized_image, .half_block, allocator);
    // try printLabeledImage("Bilinear resized (32x32)", bilinear_resized_image, .half_block, allocator);
    // try printLabeledImage("Bicubic resized (32x32)", bicubic_resized_image, .half_block, allocator);

    const box_resized_test_square_image = try resizeImage(test_square_image, 4, 4, .average, allocator);
    defer box_resized_test_square_image.deinit(allocator);

    const bilinear_resized_test_square_image = try resizeImage(test_square_image, 4, 4, .bilinear, allocator);
    defer bilinear_resized_test_square_image.deinit(allocator);

    const bicubic_resized_test_square_image = try resizeImage(test_square_image, 4, 4, .bicubic, allocator);
    defer bicubic_resized_test_square_image.deinit(allocator);

    try printLabeledImage("Original test_square_image (16x16)", test_square_image, .half_block, allocator);
    try printLabeledImage("Box resized (4x4)", box_resized_test_square_image, .full_block, allocator);
    // FIXME: This one looks different when comparing it to what other applications do
    try printLabeledImage("Bilinear resized (4x4)", bilinear_resized_test_square_image, .full_block, allocator);
    try printLabeledImage("Bicubic resized (4x4)", bicubic_resized_test_square_image, .full_block, allocator);

    const box_resized_test_color_checkerboard_image = try resizeImage(test_color_checkerboard_image, 2, 2, .average, allocator);
    defer box_resized_test_color_checkerboard_image.deinit(allocator);
    try expectImageApproxEqual(box_resized_test_color_checkerboard_image, RGBImage{
        .width = 2,
        .height = 2,
        .pixels = &rgbPixelsfromHexArray(&.{
            0x808000, 0x800080,
            0x008080, 0xff8080,
        }),
    }, PIXEL_TOLERANCE, allocator);

    try printLabeledImage("Original test_color_checkerboard_image (4x4)", test_color_checkerboard_image, .full_block, allocator);
    try printLabeledImage("Box resized (2x2)", box_resized_test_color_checkerboard_image, .full_block, allocator);

    // TODO: Test box resize with non-perfectly divisible dimensions

    return error.OkButWeShouldLookAtThisInTheFuture;
}
