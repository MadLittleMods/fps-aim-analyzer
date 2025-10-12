const std = @import("std");
const zigimg = @import("zigimg");

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

    pub fn toHexNumber(self: @This()) u24 {
        // Convert from [0, 1] to [0, 255]
        const red = @as(u8, @as(u8, @intFromFloat(self.r * 255.0)));
        const green = @as(u8, @as(u8, @intFromFloat(self.g * 255.0)));
        const blue = @as(u8, @as(u8, @intFromFloat(self.b * 255.0)));

        // Shift the red component all the way up to the top
        const red_shifted = @as(u24, @as(u24, red) << 16);
        // Shift the green component up 8 bits
        const green_shifted = @as(u24, @as(u24, green) << 8);
        // No need to shift the blue component
        const blue_shifted = @as(u24, blue);

        // Combine the shifted components
        const hex_color = red_shifted | green_shifted | blue_shifted;
        return hex_color;
    }
};

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
        errdefer allocator.free(output_rgb_pixels);
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

        // Make sure the directory exists
        const maybe_directory_to_create = std.fs.path.dirname(image_file_path);
        if (maybe_directory_to_create) |directory_to_create| {
            try std.fs.Dir.makePath(std.fs.cwd(), directory_to_create);
        }

        try img.writeToFilePath(image_file_path, .{ .png = .{} });
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

pub fn getPixelValueFieldNames(comptime PixelType: type) []const []const u8 {
    const pixel_value_field_names: []const []const u8 = comptime switch (PixelType) {
        RGBPixel => &.{ "r", "g", "b" },
        HSVPixel => &.{ "h", "s", "v" },
        GrayscalePixel => &.{"value"},
        BinaryPixel => &.{"value"},
        else => {
            @compileLog("PixelType=", @typeName(PixelType));
            @compileError("getPixelValueFieldNames(...): Unknown pixel type");
        },
    };

    return pixel_value_field_names;
}

/// Quick helper to convert a bunch of 0/1 into BinaryPixel's
pub fn binaryPixelsfromIntArray(comptime int_pixels: []const u1) [int_pixels.len]BinaryPixel {
    var binary_pixels = [_]BinaryPixel{BinaryPixel{ .value = false }} ** int_pixels.len;
    for (int_pixels, 0..) |int_pixel, index| {
        binary_pixels[index] = BinaryPixel{ .value = if (int_pixel == 1) true else false };
    }

    return binary_pixels;
}

pub fn getPixelIndexClamped(image: anytype, x: isize, y: isize) usize {
    const x_clamped = @as(usize, @intCast(
        std.math.clamp(x, 0, @as(isize, @intCast(image.width - 1))),
    ));
    const y_clamped = @as(usize, @intCast(
        std.math.clamp(y, 0, @as(isize, @intCast(image.height - 1))),
    ));
    const pixel_index = (y_clamped * image.width) + x_clamped;
    return pixel_index;
}

pub fn getPixelClamped(image: anytype, x: isize, y: isize) std.meta.Child(@TypeOf(image.pixels)) {
    const pixel_index_clamped = getPixelIndexClamped(image, x, y);
    return image.pixels[pixel_index_clamped];
}

test "getPixelIndexClamped" {
    const image = BinaryImage{
        .width = 5,
        .height = 5,
        .pixels = &binaryPixelsfromIntArray(&[_]u1{
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 1, 0,
            0, 0, 0, 0, 0,
        }),
    };

    // In bounds
    try std.testing.expectEqual(@as(usize, 0), getPixelIndexClamped(image, 0, 0));
    try std.testing.expectEqual(@as(usize, 4), getPixelIndexClamped(image, 4, 0));
    try std.testing.expectEqual(@as(usize, 20), getPixelIndexClamped(image, 0, 4));
    try std.testing.expectEqual(@as(usize, 24), getPixelIndexClamped(image, 4, 4));

    // Out of bounds are clamped
    try std.testing.expectEqual(@as(usize, 0), getPixelIndexClamped(image, -2, 0));
    try std.testing.expectEqual(@as(usize, 4), getPixelIndexClamped(image, 6, 0));
    try std.testing.expectEqual(@as(usize, 10), getPixelIndexClamped(image, -2, 2));
    try std.testing.expectEqual(@as(usize, 0), getPixelIndexClamped(image, 0, -1));
    try std.testing.expectEqual(@as(usize, 20), getPixelIndexClamped(image, 0, 6));
    try std.testing.expectEqual(@as(usize, 22), getPixelIndexClamped(image, 2, 6));
    try std.testing.expectEqual(@as(usize, 24), getPixelIndexClamped(image, 6, 6));
}
