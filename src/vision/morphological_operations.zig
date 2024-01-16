const std = @import("std");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const image_conversion = @import("image_conversion.zig");
const BinaryImage = image_conversion.BinaryImage;
const BinaryPixel = image_conversion.BinaryPixel;
const binaryToRgbImage = image_conversion.binaryToRgbImage;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

// - https://towardsdatascience.com/understanding-morphological-image-processing-and-its-operations-7bcf1ed11756
// - https://docs.opencv.org/4.x/d4/d76/tutorial_js_morphological_ops.html
// - https://docs.opencv.org/4.x/db/df6/tutorial_erosion_dilatation.html

const StructuringElementType = enum {
    rectangle,
    cross,
    ellipse,
};

pub fn getStructuringElement(
    structure_type: StructuringElementType,
    width: usize,
    height: usize,
    allocator: std.mem.Allocator,
) !BinaryImage {
    assert(width % 2 == 1, "Structuring element width must be odd so we can perfectly center it {}", .{width});
    assert(height % 2 == 1, "Structuring element height must be odd so we can perfectly center it {}", .{height});

    const output_pixels = try allocator.alloc(BinaryPixel, width * height);

    switch (structure_type) {
        .rectangle => {
            @memset(output_pixels, BinaryPixel{ .value = true });
        },
        .cross => {
            @memset(output_pixels, BinaryPixel{ .value = false });

            // Set the center row
            const center_y = height / 2;
            const row_start_index = center_y * width;
            for (0..width) |x| {
                const pixel_index = row_start_index + x;
                output_pixels[pixel_index] = BinaryPixel{ .value = true };
            }

            // Set the center column
            const center_x = width / 2;
            for (0..height) |y| {
                const pixel_index = y * width + center_x;
                output_pixels[pixel_index] = BinaryPixel{ .value = true };
            }
        },
        .ellipse => {
            // TODO
        },
    }

    return BinaryImage{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

test "getStructuringElement rectangle" {
    const allocator = std.testing.allocator;
    const actual_rect_image = try getStructuringElement(
        .rectangle,
        3,
        3,
        allocator,
    );
    defer actual_rect_image.deinit(allocator);

    const expected_rect_pixels = binaryPixelsfromIntArray(9, [_]u1{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });
    const expected_rect_image = BinaryImage{
        .width = 3,
        .height = 3,
        .pixels = &expected_rect_pixels,
    };

    try expectBinaryImageEqual(
        actual_rect_image,
        expected_rect_image,
        allocator,
    );
}

test "getStructuringElement cross" {
    const allocator = std.testing.allocator;
    const actual_cross_image = try getStructuringElement(
        .cross,
        3,
        3,
        allocator,
    );
    defer actual_cross_image.deinit(allocator);

    const expected_cross_pixels = binaryPixelsfromIntArray(9, [_]u1{
        0, 1, 0,
        1, 1, 1,
        0, 1, 0,
    });
    const expected_cross_image = BinaryImage{
        .width = 3,
        .height = 3,
        .pixels = &expected_cross_pixels,
    };

    try expectBinaryImageEqual(
        actual_cross_image,
        expected_cross_image,
        allocator,
    );
}

test "getStructuringElement ellipse" {
    // TODO
}

fn binaryPixelsfromIntArray(comptime len: usize, comptime int_pixels: [len]u1) [len]BinaryPixel {
    var binary_pixels = [_]BinaryPixel{BinaryPixel{ .value = false }} ** len;
    for (int_pixels, 0..) |int_pixel, index| {
        binary_pixels[index] = BinaryPixel{ .value = if (int_pixel == 1) true else false };
    }

    return binary_pixels;
}

fn expectBinaryImageEqual(
    actual_binary_image: BinaryImage,
    expected_binary_image: BinaryImage,
    allocator: std.mem.Allocator,
) !void {
    try std.testing.expectEqual(expected_binary_image.width, actual_binary_image.width);
    try std.testing.expectEqual(expected_binary_image.height, actual_binary_image.height);

    std.testing.expectEqualSlices(
        BinaryPixel,
        actual_binary_image.pixels,
        expected_binary_image.pixels,
    ) catch |err| {
        const actual_rgb_image = try binaryToRgbImage(actual_binary_image, allocator);
        defer actual_rgb_image.deinit(allocator);
        try printLabeledImage("Actual image", actual_rgb_image, .full_block, allocator);

        const expected_rgb_image = try binaryToRgbImage(expected_binary_image, allocator);
        defer expected_rgb_image.deinit(allocator);
        try printLabeledImage("Expected image", expected_rgb_image, .full_block, allocator);

        return err;
    };
}

//  - Fit: When all the pixels in the structuring element cover the pixels of the
//    object, we call it Fit.
//  - Hit: When at least one of the pixels in the structuring element cover the pixels
//    of the object, we call it Hit.
//  - Miss: When no pixel in the structuring element cover the pixels of the object, we
//    call it miss.

pub fn erode(
    binary_image: BinaryImage,
    /// Small-sized template/structuring element that is used to traverse an image. The
    /// structuring element is positioned at all possible locations in the image, and it
    /// is compared with the connected pixels. It can be of any shape.
    ///
    ///  The kernel must have odd length sides and we assume the origin is at the
    ///  center.
    kernel: BinaryImage,
    allocator: std.mem.Allocator,
) !BinaryImage {
    const output_pixels = try allocator.alloc(BinaryPixel, binary_image.pixels.len);
    @memset(output_pixels, BinaryPixel{ .value = false });

    for (0..binary_image.height) |y| {
        const row_start_pixel_index = y * binary_image.width;
        for (0..binary_image.width) |x| {
            const current_pixel_index = row_start_pixel_index + x;
            if (checkPixelfit(x, y, binary_image, kernel)) {
                output_pixels[current_pixel_index] = BinaryPixel{ .value = true };
            }
        }
    }

    return BinaryImage{
        .width = binary_image.width,
        .height = binary_image.height,
        .pixels = output_pixels,
    };
}

pub fn dilate(
    binary_image: BinaryImage,
    /// Small-sized template/structuring element that is used to traverse an image. The
    /// structuring element is positioned at all possible locations in the image, and it
    /// is compared with the connected pixels. It can be of any shape.
    ///
    ///  The kernel must have odd length sides and we assume the origin is at the
    ///  center.
    kernel: BinaryImage,
    allocator: std.mem.Allocator,
) !BinaryImage {
    const output_pixels = try allocator.alloc(BinaryPixel, binary_image.pixels.len);
    @memset(output_pixels, BinaryPixel{ .value = false });

    for (0..binary_image.height) |y| {
        const row_start_pixel_index = y * binary_image.width;
        for (0..binary_image.width) |x| {
            const current_pixel_index = row_start_pixel_index + x;
            if (checkPixelHit(x, y, binary_image, kernel)) {
                output_pixels[current_pixel_index] = BinaryPixel{ .value = true };
            }
        }
    }

    return BinaryImage{
        .width = binary_image.width,
        .height = binary_image.height,
        .pixels = output_pixels,
    };
}

pub fn open() !BinaryImage {}

pub fn close() !BinaryImage {}

/// Check if all the active pixels in the kernel/structuring element cover the pixels in
/// the image (fit).
pub fn checkPixelfit(image_x: usize, image_y: usize, binary_image: BinaryImage, kernel: BinaryImage) bool {
    assert(kernel.width % 2 == 1, "Kernel width must be odd so we can perfectly center it {}", .{kernel.width});
    assert(kernel.height % 2 == 1, "Kernel height must be odd so we can perfectly center it {}", .{kernel.height});

    const kernel_half_width = kernel.width / 2;
    const kernel_half_height = kernel.height / 2;

    for (0..kernel.height) |kernel_y| {
        const kernel_row_start_pixel_index = kernel_y * kernel.width;

        // Some of the kernel is outside of the image vertically
        if (
        // Check above. We use `kernel_half_height > image_y + kernel_y` to avoid
        // integer underflow/overflow since the result could be negative if we used the
        // equivalent logic: `image_y + kernel_y - kernel_half_height < 0`
        kernel_half_height > image_y + kernel_y or
            // Check below
            image_y + kernel_y - kernel_half_height >= binary_image.height)
        {
            // Miss
            return false;
        }
        const image_y_transposed = image_y + kernel_y - kernel_half_height;
        const image_row_start_pixel_index = image_y_transposed * binary_image.width;

        for (0..kernel.width) |kernel_x| {
            const kernel_pixel_index = kernel_row_start_pixel_index + kernel_x;

            // Some of the kernel is outside of the image horizontally
            if (
            // Check above. We use `kernel_half_width > image_x + kernel_x` to avoid
            // integer underflow/overflow since the result could be negative if we used
            // the equivalent logic: `image_x + kernel_x - kernel_half_width < 0`
            kernel_half_width > image_x + kernel_x or
                // Check below
                image_x + kernel_x - kernel_half_width >= binary_image.width)
            {
                // Miss
                return false;
            }
            const image_x_transposed = image_x + kernel_x - kernel_half_width;
            const image_pixel_index = image_row_start_pixel_index + image_x_transposed;

            // If the kernel pixel is true, then the image pixel must also be true
            if (kernel.pixels[kernel_pixel_index].value and !binary_image.pixels[image_pixel_index].value) {
                // Miss
                return false;
            }
        }
    }

    // Fit
    return true;
}

/// Check if at least one of the active pixels in the kernel/structuring element cover
/// the pixel of the image (hit).
pub fn checkPixelHit(image_x: usize, image_y: usize, binary_image: BinaryImage, kernel: BinaryImage) bool {
    assert(kernel.width % 2 == 1, "Kernel width must be odd so we can perfectly center it {}", .{kernel.width});
    assert(kernel.height % 2 == 1, "Kernel height must be odd so we can perfectly center it {}", .{kernel.height});

    const kernel_half_width = kernel.width / 2;
    const kernel_half_height = kernel.height / 2;

    for (0..kernel.height) |kernel_y| {
        const kernel_row_start_pixel_index = kernel_y * kernel.width;

        // Some of the kernel is outside of the image vertically
        if (
        // Check above. We use `kernel_half_height > image_y + kernel_y` to avoid
        // integer underflow/overflow since the result could be negative if we used the
        // equivalent logic: `image_y + kernel_y - kernel_half_height < 0`
        kernel_half_height > image_y + kernel_y or
            // Check below
            image_y + kernel_y - kernel_half_height >= binary_image.height)
        {
            // Maybe the next kernel pixel is inside the image so continue
            continue;
        }
        const image_y_transposed = image_y + kernel_y - kernel_half_height;
        const image_row_start_pixel_index = image_y_transposed * binary_image.width;

        for (0..kernel.width) |kernel_x| {
            const kernel_pixel_index = kernel_row_start_pixel_index + kernel_x;

            // Some of the kernel is outside of the image horizontally
            if (
            // Check above. We use `kernel_half_width > image_x + kernel_x` to avoid
            // integer underflow/overflow since the result could be negative if we used
            // the equivalent logic: `image_x + kernel_x - kernel_half_width < 0`
            kernel_half_width > image_x + kernel_x or
                // Check below
                image_x + kernel_x - kernel_half_width >= binary_image.width)
            {
                // Maybe the next kernel pixel is inside the image so continue
                continue;
            }
            const image_x_transposed = image_x + kernel_x - kernel_half_width;
            const image_pixel_index = image_row_start_pixel_index + image_x_transposed;

            // If the kernel pixel is true, then the image pixel must also be true
            if (kernel.pixels[kernel_pixel_index].value and binary_image.pixels[image_pixel_index].value) {
                // Hit
                return true;
            }
        }
    }

    // Miss
    return false;
}

test "erode" {
    const allocator = std.testing.allocator;

    // via https://towardsdatascience.com/understanding-morphological-image-processing-and-its-operations-7bcf1ed11756
    const test_binary_image_pixels = binaryPixelsfromIntArray(64, [_]u1{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 1, 0, 0,
        0, 0, 1, 1, 1, 1, 0, 0,
        0, 1, 1, 1, 1, 0, 0, 0,
        0, 1, 1, 1, 0, 0, 0, 0,
        0, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    });
    const test_binary_image = BinaryImage{
        .width = 8,
        .height = 8,
        .pixels = &test_binary_image_pixels,
    };

    // Erode with a cross structuring element
    const cross_structuring_element = try getStructuringElement(
        .cross,
        3,
        3,
        allocator,
    );
    defer cross_structuring_element.deinit(allocator);
    const eroded_binary_image = try erode(
        test_binary_image,
        cross_structuring_element,
        allocator,
    );
    defer eroded_binary_image.deinit(allocator);

    const expected_eroded_image_pixels = binaryPixelsfromIntArray(64, [_]u1{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 1, 1, 0, 0, 0, 0,
        0, 0, 1, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    });
    const expected_eroded_image = BinaryImage{
        .width = 8,
        .height = 8,
        .pixels = &expected_eroded_image_pixels,
    };

    try expectBinaryImageEqual(
        eroded_binary_image,
        expected_eroded_image,
        allocator,
    );
}

test "dilate" {
    const allocator = std.testing.allocator;

    // via https://towardsdatascience.com/understanding-morphological-image-processing-and-its-operations-7bcf1ed11756
    const test_binary_image_pixels = binaryPixelsfromIntArray(64, [_]u1{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 1, 0, 0,
        0, 0, 1, 1, 1, 1, 0, 0,
        0, 1, 1, 1, 1, 0, 0, 0,
        0, 1, 1, 1, 0, 0, 0, 0,
        0, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    });
    const test_binary_image = BinaryImage{
        .width = 8,
        .height = 8,
        .pixels = &test_binary_image_pixels,
    };

    // Dilate with a cross structuring element
    const cross_structuring_element = try getStructuringElement(
        .cross,
        3,
        3,
        allocator,
    );
    defer cross_structuring_element.deinit(allocator);
    const dilated_binary_image = try dilate(
        test_binary_image,
        cross_structuring_element,
        allocator,
    );
    defer dilated_binary_image.deinit(allocator);

    const expected_dilated_image_pixels = binaryPixelsfromIntArray(64, [_]u1{
        0, 0, 0, 1, 1, 1, 0, 0,
        0, 0, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 0, 0,
        1, 1, 1, 1, 1, 0, 0, 0,
        1, 1, 1, 1, 1, 0, 0, 0,
        0, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    });
    const expected_dilated_image = BinaryImage{
        .width = 8,
        .height = 8,
        .pixels = &expected_dilated_image_pixels,
    };

    try expectBinaryImageEqual(
        dilated_binary_image,
        expected_dilated_image,
        allocator,
    );
}
