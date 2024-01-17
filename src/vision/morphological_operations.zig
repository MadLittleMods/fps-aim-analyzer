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

/// Create a small-sized template/structuring element (kernel) that can be used with
/// morphological operations like `erode` and `dilate`.
pub fn getStructuringElement(
    structure_type: StructuringElementType,
    width: usize,
    height: usize,
    allocator: std.mem.Allocator,
) !BinaryImage {
    assert(width % 2 == 1, "Structuring element width must be odd so we can perfectly center it {}", .{width});
    assert(height % 2 == 1, "Structuring element height must be odd so we can perfectly center it {}", .{height});

    const output_pixels = try allocator.alloc(BinaryPixel, width * height);

    const center_x = width / 2;
    const center_y = height / 2;

    switch (structure_type) {
        .rectangle => {
            @memset(output_pixels, BinaryPixel{ .value = true });
        },
        .cross => {
            @memset(output_pixels, BinaryPixel{ .value = false });

            // Set the center row
            const row_start_index = center_y * width;
            for (0..width) |x| {
                const pixel_index = row_start_index + x;
                output_pixels[pixel_index] = BinaryPixel{ .value = true };
            }

            // Set the center column
            for (0..height) |y| {
                const pixel_index = y * width + center_x;
                output_pixels[pixel_index] = BinaryPixel{ .value = true };
            }
        },
        .ellipse => {
            @memset(output_pixels, BinaryPixel{ .value = false });

            // The following implementation gives different results than OpenCV's
            // `cv.getStructuringElement(cv.MORPH_ELLIPSE, ...)` (OpenCV implementation:
            // https://github.com/opencv/opencv/blob/84bb1cda4ea6135d9eb915e9ae2e348e858cc1f2/modules/imgproc/src/morph.dispatch.cpp#L135-L186)
            //
            // Based on https://stackoverflow.com/questions/59971407/how-can-i-test-if-a-point-is-in-an-ellipse/65601453#65601453
            const radius_x = center_x;
            const radius_y = center_y;
            const squared_radius = radius_x * radius_x;

            for (0..height) |y| {
                const row_start_index = y * width;
                for (0..width) |x| {
                    const pixel_index = row_start_index + x;

                    // Absolute difference between the pixel and the center of the ellipse
                    const dx = if (x > center_x) x - center_x else center_x - x;
                    const raw_dy = if (y > center_y) y - center_y else center_y - y;
                    // We also scale the y-axis by the ratio the axis
                    // (`radius_x/radius_y`) to stretch the ellipse into a circle. This
                    // simplifes the problem into a point-in-circle problem.
                    //
                    // We do the multiplication first followed by division to play nice
                    // with integer math.
                    const dy = (raw_dy * radius_x) / radius_y;

                    // Check if the pixel is inside the circle
                    const squared_distance = dx * dx + dy * dy;
                    if (squared_distance <= squared_radius) {
                        output_pixels[pixel_index] = BinaryPixel{ .value = true };
                    }
                }
            }
        },
    }

    return BinaryImage{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

test "getStructuringElement rectangle" {
    try _testStructuringElement(.rectangle, 3, 3, &[_]u1{
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
    });
}

test "getStructuringElement cross" {
    try _testStructuringElement(.cross, 3, 3, &[_]u1{
        0, 1, 0,
        1, 1, 1,
        0, 1, 0,
    });

    try _testStructuringElement(.cross, 7, 7, &[_]u1{
        0, 0, 0, 1, 0, 0, 0,
        0, 0, 0, 1, 0, 0, 0,
        0, 0, 0, 1, 0, 0, 0,
        1, 1, 1, 1, 1, 1, 1,
        0, 0, 0, 1, 0, 0, 0,
        0, 0, 0, 1, 0, 0, 0,
        0, 0, 0, 1, 0, 0, 0,
    });
}

test "getStructuringElement ellipse" {
    // 3x3 circle/ellipse
    try _testStructuringElement(.ellipse, 3, 3, &[_]u1{
        0, 1, 0,
        1, 1, 1,
        0, 1, 0,
    });

    // 5x5 circle/ellipse
    try _testStructuringElement(.ellipse, 5, 5, &[_]u1{
        0, 0, 1, 0, 0,
        0, 1, 1, 1, 0,
        1, 1, 1, 1, 1,
        0, 1, 1, 1, 0,
        0, 0, 1, 0, 0,
    });
    // OpenCV
    // 0, 0, 1, 0, 0,
    // 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1,
    // 0, 0, 1, 0, 0,

    // 15x15 circle/ellipse
    try _testStructuringElement(.ellipse, 15, 15, &[_]u1{
        0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    });
    // OpenCV
    // 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    // 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
    // 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
    // 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
    // 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,

    // 3x5 ellipse
    try _testStructuringElement(.ellipse, 3, 5, &[_]u1{
        0, 1, 0,
        1, 1, 1,
        1, 1, 1,
        1, 1, 1,
        0, 1, 0,
    });
    // (OpenCV matches)

    // 9x5 ellipse
    try _testStructuringElement(.ellipse, 9, 5, &[_]u1{
        0, 0, 0, 0, 1, 0, 0, 0, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1,
        0, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 0, 0, 0, 1, 0, 0, 0, 0,
    });
    // (OpenCV matches)

    // 17x11 ellipse
    try _testStructuringElement(.ellipse, 17, 11, &[_]u1{
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
        0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
        0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    });
    // OpenCV
    // 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
    // 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    // 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    // 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0,
    // 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0,
    // 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
}

/// Compare the actual output from `getStructuringElement` to a map of expected pixels.
fn _testStructuringElement(structure_type: StructuringElementType, width: usize, height: usize, comptime expected_int_pixels: []const u1) !void {
    const allocator = std.testing.allocator;

    const actual_structuring_element = try getStructuringElement(
        structure_type,
        width,
        height,
        allocator,
    );
    defer actual_structuring_element.deinit(allocator);

    const expected_pixels = _binaryPixelsfromIntArray(expected_int_pixels);
    const expected_image = BinaryImage{
        .width = width,
        .height = height,
        .pixels = &expected_pixels,
    };

    try _expectBinaryImageEqual(
        actual_structuring_element,
        expected_image,
        allocator,
    );
}

/// Quick helper to convert a bunch of 0/1 into BinaryPixel's
fn _binaryPixelsfromIntArray(comptime int_pixels: []const u1) [int_pixels.len]BinaryPixel {
    var binary_pixels = [_]BinaryPixel{BinaryPixel{ .value = false }} ** int_pixels.len;
    for (int_pixels, 0..) |int_pixel, index| {
        binary_pixels[index] = BinaryPixel{ .value = if (int_pixel == 1) true else false };
    }

    return binary_pixels;
}

fn _expectBinaryImageEqual(
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

/// The kernel slides through the image and only pixels that have neighbors matching the
/// kernel are copied to the output/result.
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
    std.debug.print("\nerode {}x{}", .{ kernel.width, kernel.height });
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
    std.debug.print("\ndilate {}x{}", .{ kernel.width, kernel.height });
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

/// Opening is just another name for erosion followed by dilation. It is useful in
/// removing noise.
pub fn opening(
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
    const eroded_binary_image = try erode(
        binary_image,
        kernel,
        allocator,
    );
    defer eroded_binary_image.deinit(allocator);

    const dilated_binary_image = try dilate(
        eroded_binary_image,
        kernel,
        allocator,
    );

    return dilated_binary_image;
}

/// Closing is just another name for dilation followed by erosion (reverse of
/// "opening"). It is useful in closing small holes inside the foreground objects, or
/// small black points on the object.
pub fn closing(
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
    const dilated_binary_image = try dilate(
        binary_image,
        kernel,
        allocator,
    );
    defer dilated_binary_image.deinit(allocator);

    const eroded_binary_image = try erode(
        dilated_binary_image,
        kernel,
        allocator,
    );

    return eroded_binary_image;
}

/// Check if all the active pixels in the kernel/structuring element cover the pixels in
/// the image (fit).
///
//  - Fit: When all the pixels in the structuring element cover the pixels of the
//    object, we call it Fit.
//  - Hit: When at least one of the pixels in the structuring element cover the pixels
//    of the object, we call it Hit.
//  - Miss: When no pixel in the structuring element cover the pixels of the object, we
//    call it miss.
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
///
//  - Fit: When all the pixels in the structuring element cover the pixels of the
//    object, we call it Fit.
//  - Hit: When at least one of the pixels in the structuring element cover the pixels
//    of the object, we call it Hit.
//  - Miss: When no pixel in the structuring element cover the pixels of the object, we
//    call it miss.
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

// via https://towardsdatascience.com/understanding-morphological-image-processing-and-its-operations-7bcf1ed11756
const test_binary_image_pixels = _binaryPixelsfromIntArray(&[_]u1{
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

test "erode" {
    const allocator = std.testing.allocator;

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

    const expected_eroded_image_pixels = _binaryPixelsfromIntArray(&[_]u1{
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

    try _expectBinaryImageEqual(
        eroded_binary_image,
        expected_eroded_image,
        allocator,
    );
}

test "dilate" {
    const allocator = std.testing.allocator;

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

    const expected_dilated_image_pixels = _binaryPixelsfromIntArray(&[_]u1{
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

    try _expectBinaryImageEqual(
        dilated_binary_image,
        expected_dilated_image,
        allocator,
    );
}
