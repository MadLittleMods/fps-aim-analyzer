const std = @import("std");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const image_conversion = @import("image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const RGBPixel = image_conversion.RGBPixel;
const BinaryImage = image_conversion.BinaryImage;
const BinaryPixel = image_conversion.BinaryPixel;
const binaryPixelsfromIntArray = image_conversion.binaryPixelsfromIntArray;
const binaryToRgbImage = image_conversion.binaryToRgbImage;
const print_utils = @import("../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

// https://theailearner.com/tag/contour-tracing-algorithms/
// https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/alg.html
// https://en.wikipedia.org/wiki/Boundary_tracing
//
//  - Square Tracing algorithm
//  - Moore Boundary Tracing algorithm
//  - Radial Sweep
//  - Theo Pavlidis’ algorithm
//  - Dr. Kovalevsky algorithm
//  - Suzuki’s Algorithm (OpenCV)
//  - Fast contour tracing algorithm, https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4813928/

const ContourMethod = enum {
    square,
};

/// Image coordinate system that allows out of bounds coordinates.
/// Top-left is (0, 0),bottom-right is (width, height).
const CanvasPoint = struct {
    x: isize,
    y: isize,

    pub fn fromImagePoint(image_point: ImagePoint) CanvasPoint {
        return CanvasPoint{
            .x = @intCast(image_point.x),
            .y = @intCast(image_point.y),
        };
    }

    pub fn stepInDirection(current_point: @This(), step_direction: StepDirection) @This() {
        return CanvasPoint{
            .x = current_point.x + step_direction.x,
            .y = current_point.y + step_direction.y,
        };
    }
};

/// A coordinate that exists within an image.
/// Top-left is (0, 0),bottom-right is (width, height).
const ImagePoint = struct {
    x: usize,
    y: usize,

    pub fn fromCanvasPoint(canvas_point: CanvasPoint) ImagePoint {
        assert(canvas_point.x >= 0, "Unable to convert canvas point to image point since the x coordinate is negative {any}", .{
            canvas_point,
        });
        assert(canvas_point.y >= 0, "Unable to convert canvas point to image point since the y coordinate is negative {any}", .{
            canvas_point,
        });

        return ImagePoint{
            .x = @intCast(canvas_point.x),
            .y = @intCast(canvas_point.y),
        };
    }
};

/// Assumes image coordinate system where the top-left is (0, 0), / bottom-right is
/// (width, height)
const StepDirection = struct {
    x: isize,
    y: isize,

    pub const Right = StepDirection{ .x = 1, .y = 0 };
    pub const Left = StepDirection{ .x = -1, .y = 0 };
    pub const Up = StepDirection{ .x = 0, .y = -1 };
    pub const Down = StepDirection{ .x = 0, .y = 1 };
};

/// Caveats:
///  - Finds a single contour in a binary image. If there are multiple objects, trace the
///    boundary of first object then mask the object using the boundary.
///  - Can only find the outer contour of 4-connected pixels (pixels that are connected
///    by their edges). Not bullet-proof for 8-connected pixels (all surrounding
///    pixels).
///
/// Square tracing algorithm:
///  - Scan across the rows/columns however you please to find a starting pixel and the
///    direction you entered it from while scanning
///  - Every time you find yourself standing on a black pixel, turn left, and
///  - Every time you find yourself standing on a white pixel, turn right,
///  - until you meet the stop criteria
///
/// References:
///  - https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
///  - https://en.wikipedia.org/wiki/Boundary_tracing#Square_tracing_algorithm
pub fn squareContourTracing(
    binary_image: BinaryImage,
    start_point: ImagePoint,
    start_direction: StepDirection,
    allocator: std.mem.Allocator,
) ![]const ImagePoint {
    const start_canvas_point = CanvasPoint.fromImagePoint(start_point);
    // Sanity check that someone passed an active pixel as the start point
    if (!binary_image.pixels[(start_point.y * binary_image.width) + start_point.x].value) {
        std.log.err("squareContourTracing: start_point {}x{} must be active but was inactive", .{
            start_point.x,
            start_point.y,
        });
        return error.StartPointNotActive;
    }

    // We use a hash map to avoid duplicates
    var boundary_points = std.AutoArrayHashMap(ImagePoint, void).init(allocator);
    defer boundary_points.deinit();
    // We found at least one active pixel
    try boundary_points.put(start_point, {});

    // The first pixel you encounter is a white one by definition, so we go left
    var current_direction = _turnLeft(start_direction);
    var current_point: CanvasPoint = CanvasPoint.stepInDirection(
        start_canvas_point,
        current_direction,
    );

    // Jacob's stopping criterion: Stop after entering the start pixel a second time in
    // the same direction you entered it initially
    while (!(std.meta.eql(current_point, start_canvas_point) and
        std.meta.eql(current_direction, start_direction)))
    {
        // Be careful to not go out of bounds while getting the current pixel index
        const optional_current_pixel_index: ?usize = blk: {
            const is_current_point_in_image_bounds = current_point.x >= 0 and
                current_point.x < binary_image.width and
                current_point.y >= 0 and
                current_point.y < binary_image.height;

            if (is_current_point_in_image_bounds) {
                const current_image_point = ImagePoint.fromCanvasPoint(current_point);
                break :blk (current_image_point.y * binary_image.width) + current_image_point.x;
            }

            break :blk null;
        };

        if (optional_current_pixel_index != null and binary_image.pixels[optional_current_pixel_index.?].value) {
            // We found another active boundary pixel
            try boundary_points.put(ImagePoint.fromCanvasPoint(current_point), {});
            // The current pixel is active, so we go left
            current_direction = _turnLeft(current_direction);
            current_point = CanvasPoint.stepInDirection(
                current_point,
                current_direction,
            );
        } else {
            // The current pixel is inactive, so we go right
            current_direction = _turnRight(current_direction);
            current_point = CanvasPoint.stepInDirection(
                current_point,
                current_direction,
            );
        }
    }

    const owned_boundary_points = try allocator.alloc(ImagePoint, boundary_points.keys().len);
    @memcpy(owned_boundary_points, boundary_points.keys());
    return owned_boundary_points;
}

/// Note: This function assumes the image coordinate system where the top-left is (0,
/// 0), bottom-right is (width, height)
fn _turnLeft(step_direction: StepDirection) StepDirection {
    return .{ .x = step_direction.y, .y = -step_direction.x };
}
/// Note: This function assumes the image coordinate system where the top-left is (0,
/// 0), bottom-right is (width, height)
fn _turnRight(step_direction: StepDirection) StepDirection {
    return .{ .x = -step_direction.y, .y = step_direction.x };
}

test "findContours (single) (squareContourTracing)" {
    const allocator = std.testing.allocator;

    // Simple rectangle
    try _testFindContours(
        BinaryImage{
            .width = 6,
            .height = 7,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0,
                0, 0, 1, 1, 1, 0,
                0, 0, 1, 1, 1, 0,
                0, 0, 1, 1, 1, 0,
                0, 0, 1, 1, 1, 0,
                0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 2, .y = 4 }, .{ .x = 2, .y = 3 },
                .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 1 },
                .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 },
                .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 },
                .{ .x = 4, .y = 4 }, .{ .x = 3, .y = 4 },
            },
        },
        allocator,
    );

    // Test to make sure we can detect contours on the outer edges of the image
    try _testFindContours(
        BinaryImage{
            .width = 4,
            .height = 4,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                1, 1, 1, 1,
                1, 0, 1, 1,
                1, 0, 1, 1,
                1, 1, 1, 1,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 0, .y = 3 }, .{ .x = 0, .y = 2 },
                .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 },
                .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
                .{ .x = 3, .y = 0 }, .{ .x = 3, .y = 1 },
                .{ .x = 3, .y = 2 }, .{ .x = 3, .y = 3 },
                .{ .x = 2, .y = 3 }, .{ .x = 1, .y = 3 },
            },
        },
        allocator,
    );

    // Complex shape from the "Demonstration" section on
    // https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
    try _testFindContours(
        BinaryImage{
            .width = 6,
            .height = 7,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0,
                0, 0, 0, 1, 0, 0,
                0, 0, 1, 1, 1, 0,
                0, 0, 0, 1, 1, 0,
                0, 0, 1, 1, 0, 0,
                0, 0, 1, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 4 },
                .{ .x = 3, .y = 3 },
                // TODO: Not sure this point should be included
                .{ .x = 3, .y = 2 },
                .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 1 },
                .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 3 },
                .{ .x = 3, .y = 4 },
            },
        },
        allocator,
    );

    // Test Jacob's stopping criterion.
    // Example is from the "The Stopping Criterion" section on
    // https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
    try _testFindContours(
        BinaryImage{
            .width = 8,
            .height = 7,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 1, 0, 1, 0, 0,
                0, 0, 0, 1, 1, 1, 0, 0,
                0, 0, 0, 0, 1, 0, 1, 0,
                0, 0, 1, 0, 1, 1, 0, 0,
                0, 0, 1, 1, 1, 0, 1, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 4 },
                .{ .x = 3, .y = 5 }, .{ .x = 4, .y = 4 },
                .{ .x = 4, .y = 3 }, .{ .x = 3, .y = 2 },
                .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 2 },
                .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 2 },
                .{ .x = 6, .y = 3 }, .{ .x = 5, .y = 4 },
                .{ .x = 6, .y = 5 }, .{ .x = 4, .y = 5 },
            },
        },
        allocator,
    );

    // K/wedge shape
    try _testFindContours(
        BinaryImage{
            .width = 6,
            .height = 7,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0,
                0, 1, 1, 1, 1, 0,
                0, 1, 1, 1, 0, 0,
                0, 1, 1, 0, 0, 0,
                0, 1, 1, 1, 0, 0,
                0, 1, 1, 1, 1, 0,
                0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 1, .y = 5 }, .{ .x = 1, .y = 4 },
                .{ .x = 1, .y = 3 }, .{ .x = 1, .y = 2 },
                .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
                .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 },
                .{ .x = 3, .y = 2 }, .{ .x = 2, .y = 3 },
                // TODO: Not sure this point should be included
                .{ .x = 2, .y = 4 }, .{ .x = 3, .y = 4 },
                .{ .x = 3, .y = 5 }, .{ .x = 4, .y = 5 },
                .{ .x = 2, .y = 5 },
            },
        },
        allocator,
    );
}

test "findContours (multiple) (squareContourTracing)" {
    const allocator = std.testing.allocator;

    // Simple rectangles
    try _testFindContours(
        BinaryImage{
            .width = 9,
            .height = 7,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0, 0, 0, 0,
                1, 1, 1, 0, 1, 1, 1, 1, 0,
                1, 1, 1, 0, 1, 1, 1, 1, 0,
                1, 1, 1, 0, 1, 1, 1, 1, 0,
                1, 1, 1, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 3 },
                .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 },
                .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 },
                .{ .x = 2, .y = 4 }, .{ .x = 1, .y = 4 },
            },
            &.{
                .{ .x = 4, .y = 3 }, .{ .x = 4, .y = 2 },
                .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 },
                .{ .x = 6, .y = 1 }, .{ .x = 7, .y = 1 },
                .{ .x = 7, .y = 2 }, .{ .x = 7, .y = 3 },
                .{ .x = 6, .y = 3 }, .{ .x = 5, .y = 3 },
            },
        },
        allocator,
    );

    // // Does not find holes
    // try _testFindContours(
    //     BinaryImage{
    //         .width = 9,
    //         .height = 8,
    //         .pixels = &binaryPixelsfromIntArray(&[_]u1{
    //             0, 0, 0, 0, 0, 0, 0, 0, 0,
    //             0, 1, 1, 1, 1, 1, 1, 1, 0,
    //             0, 1, 1, 1, 1, 1, 1, 1, 0,
    //             0, 1, 1, 0, 1, 1, 1, 1, 0,
    //             0, 1, 1, 0, 1, 1, 1, 1, 0,
    //             0, 1, 1, 1, 1, 1, 1, 0, 0,
    //             0, 1, 1, 1, 1, 1, 0, 0, 0,
    //             0, 0, 0, 0, 0, 0, 0, 0, 0,
    //         }),
    //     },
    //     .square,
    //     &.{
    //         &.{
    //             .{ .x = 1, .y = 6 }, .{ .x = 1, .y = 5 },
    //             .{ .x = 1, .y = 4 }, .{ .x = 1, .y = 3 },
    //             .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 1 },
    //             .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 },
    //             .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 },
    //             .{ .x = 6, .y = 1 }, .{ .x = 7, .y = 1 },
    //             .{ .x = 7, .y = 2 }, .{ .x = 7, .y = 3 },
    //             .{ .x = 7, .y = 4 }, .{ .x = 6, .y = 4 },
    //             .{ .x = 6, .y = 5 }, .{ .x = 5, .y = 5 },
    //             .{ .x = 5, .y = 6 }, .{ .x = 4, .y = 6 },
    //             .{ .x = 3, .y = 6 }, .{ .x = 2, .y = 6 },
    //         },
    //     },
    //     allocator,
    // );

    // K/wedge shape with fitting triangle
    try _testFindContours(
        BinaryImage{
            .width = 9,
            .height = 13,
            .pixels = &binaryPixelsfromIntArray(&[_]u1{
                0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 1, 1, 1, 1, 1, 1, 1, 0,
                0, 1, 1, 1, 1, 1, 1, 0, 0,
                0, 1, 1, 1, 1, 1, 0, 0, 0,
                0, 1, 1, 1, 1, 0, 0, 1, 0,
                0, 1, 1, 1, 0, 0, 1, 1, 0,
                0, 1, 1, 0, 0, 1, 1, 1, 0,
                0, 1, 1, 1, 0, 0, 1, 1, 0,
                0, 1, 1, 1, 1, 0, 0, 1, 0,
                0, 1, 1, 1, 1, 1, 0, 0, 0,
                0, 1, 1, 1, 1, 1, 1, 0, 0,
                0, 1, 1, 1, 1, 1, 1, 1, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0,
            }),
        },
        .square,
        &.{
            &.{
                .{ .x = 1, .y = 11 }, .{ .x = 1, .y = 10 },
                .{ .x = 1, .y = 9 },  .{ .x = 1, .y = 8 },
                .{ .x = 1, .y = 7 },  .{ .x = 1, .y = 6 },
                .{ .x = 1, .y = 5 },  .{ .x = 1, .y = 4 },
                .{ .x = 1, .y = 3 },  .{ .x = 1, .y = 2 },
                .{ .x = 1, .y = 1 },  .{ .x = 2, .y = 1 },
                .{ .x = 3, .y = 1 },  .{ .x = 4, .y = 1 },
                .{ .x = 5, .y = 1 },  .{ .x = 6, .y = 1 },
                .{ .x = 7, .y = 1 },  .{ .x = 6, .y = 2 },
                .{ .x = 5, .y = 2 },  .{ .x = 5, .y = 3 },
                .{ .x = 4, .y = 3 },  .{ .x = 4, .y = 4 },
                .{ .x = 3, .y = 4 },  .{ .x = 3, .y = 5 },
                .{ .x = 2, .y = 5 },  .{ .x = 2, .y = 6 },
                .{ .x = 3, .y = 7 },  .{ .x = 4, .y = 8 },
                .{ .x = 5, .y = 9 },  .{ .x = 6, .y = 10 },
                .{ .x = 7, .y = 11 }, .{ .x = 6, .y = 11 },
                .{ .x = 5, .y = 11 }, .{ .x = 4, .y = 11 },
                .{ .x = 3, .y = 11 }, .{ .x = 2, .y = 11 },
            },
            &.{
                .{ .x = 5, .y = 6 }, .{ .x = 6, .y = 6 },
                .{ .x = 6, .y = 5 }, .{ .x = 7, .y = 5 },
                .{ .x = 7, .y = 4 }, .{ .x = 7, .y = 6 },
                .{ .x = 7, .y = 7 }, .{ .x = 7, .y = 8 },
                .{ .x = 6, .y = 7 },
            },
        },
        allocator,
    );
}

fn _testFindContours(
    binary_image: BinaryImage,
    contour_method: ContourMethod,
    expected_contours: []const []const ImagePoint,
    allocator: std.mem.Allocator,
) !void {
    const contours = try findContours(
        binary_image,
        contour_method,
        allocator,
    );
    defer {
        for (contours) |contour| {
            allocator.free(contour);
        }
        allocator.free(contours);
    }

    std.testing.expectEqual(expected_contours.len, contours.len) catch |err| {
        var rgb_image = try binaryToRgbImage(binary_image, allocator);
        defer rgb_image.deinit(allocator);
        for (contours, 0..) |contour, contour_index| {
            const previous_rgb_image = rgb_image;
            defer previous_rgb_image.deinit(allocator);

            rgb_image = try _traceContourOnRgbImage(
                rgb_image,
                contour,
                switch (contour_index % 4) {
                    0 => RGBPixel.fromHexNumber(0xff0000),
                    1 => RGBPixel.fromHexNumber(0x00ff00),
                    2 => RGBPixel.fromHexNumber(0xff00ff),
                    3 => RGBPixel.fromHexNumber(0xffff00),
                    else => unreachable,
                },
                allocator,
            );
        }
        try printLabeledImage(
            "Contour traced image",
            rgb_image,
            .full_block,
            allocator,
        );

        return err;
    };

    for (contours, expected_contours, 0..) |contour, expected_contour, contour_index| {
        const extra_label_string = try std.fmt.allocPrint(
            allocator,
            "index {}",
            .{contour_index},
        );
        defer allocator.free(extra_label_string);
        try _expectContourEqual(
            binary_image,
            contour,
            expected_contour,
            extra_label_string,
            allocator,
        );
    }
}

/// Trace the contour on the image with red pixels
fn _traceContourOnRgbImage(
    rgb_image: RGBImage,
    contour_boundary: []const ImagePoint,
    tracing_color: RGBPixel,
    allocator: std.mem.Allocator,
) !RGBImage {
    var mutable_pixels = try allocator.alloc(RGBPixel, rgb_image.pixels.len);
    std.mem.copyForwards(RGBPixel, mutable_pixels, rgb_image.pixels);

    for (contour_boundary) |contour_point| {
        const pixel_index = (contour_point.y * rgb_image.width) + contour_point.x;
        const modifier: f32 = if (mutable_pixels[pixel_index].r == 1.0) 1.0 else 0.5;
        mutable_pixels[pixel_index] = .{
            .r = tracing_color.r * modifier,
            .g = tracing_color.g * modifier,
            .b = tracing_color.b * modifier,
        };
    }

    return .{
        .width = rgb_image.width,
        .height = rgb_image.height,
        .pixels = mutable_pixels,
    };
}

/// Compare two contours and print some useful debugging information/context if they're
/// not equal
fn _expectContourEqual(
    binary_image: BinaryImage,
    actual_contour_boundary: []const ImagePoint,
    expected_contour_boundary: []const ImagePoint,
    extra_label: []const u8,
    allocator: std.mem.Allocator,
) !void {
    std.testing.expectEqualSlices(
        ImagePoint,
        expected_contour_boundary,
        actual_contour_boundary,
    ) catch |err| {
        const rgb_image = try binaryToRgbImage(binary_image, allocator);
        defer rgb_image.deinit(allocator);

        // Print the actual contour
        const actual_rgb_image = try _traceContourOnRgbImage(
            rgb_image,
            actual_contour_boundary,
            RGBPixel.fromHexNumber(0xff0000),
            allocator,
        );
        defer actual_rgb_image.deinit(allocator);
        // Construct a label
        const actual_label_string = try std.fmt.allocPrint(
            allocator,
            "Actual contour ({s})",
            .{extra_label},
        );
        defer allocator.free(actual_label_string);
        try printLabeledImage(
            actual_label_string,
            actual_rgb_image,
            .full_block,
            allocator,
        );

        // Print the expected contour
        const expected_rgb_image = try _traceContourOnRgbImage(
            rgb_image,
            expected_contour_boundary,
            RGBPixel.fromHexNumber(0xff0000),
            allocator,
        );
        defer expected_rgb_image.deinit(allocator);
        // Construct a label
        const expected_label_string = try std.fmt.allocPrint(
            allocator,
            "Expected contour ({s})",
            .{extra_label},
        );
        defer allocator.free(expected_label_string);
        try printLabeledImage(
            expected_label_string,
            expected_rgb_image,
            .full_block,
            allocator,
        );

        return err;
    };
}

/// Moore Boundary Tracing algorithm, Moore-Neighbor Tracing
///
/// References:
///  - https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/moore.html
///  - https://en.wikipedia.org/wiki/Moore_neighborhood
pub fn mooreContourTracing(binary_image: BinaryImage, allocator: std.mem.Allocator) void {
    _ = allocator;
    _ = binary_image;
    // TODO
    @compileError("Not implemented");
}

/// Find all contours in a binary image.
pub fn findContours(binary_image: BinaryImage, contour_method: ContourMethod, allocator: std.mem.Allocator) ![]const []const ImagePoint {
    var contours = std.ArrayList([]const ImagePoint).init(allocator);
    errdefer contours.deinit();

    var seen_boundary_points = std.AutoArrayHashMap(ImagePoint, void).init(allocator);
    defer seen_boundary_points.deinit();

    // Find the starting point
    //
    // Starting from the left-most column, scan bottom-up until we find the first active
    // pixel
    var start_point: ImagePoint = undefined;
    var start_direction: StepDirection = undefined;
    // Start from the left-most column
    for (0..binary_image.width) |x| {
        // Scan bottom-up
        var y = binary_image.height - 1;
        while (y > 0) : (y -%= 1) {
            const current_pixel_index = (y * binary_image.width) + x;
            // Be careful to not go out of bounds while getting the pixel index
            const optional_last_pixel_index: ?usize = blk: {
                const is_point_in_image_bounds = x >= 0 and
                    x < binary_image.width and
                    (y + 1) >= 0 and
                    (y + 1) < binary_image.height;

                if (is_point_in_image_bounds) {
                    const last_pixel_index = ((y + 1) * binary_image.width) + x;
                    break :blk last_pixel_index;
                }

                break :blk null;
            };

            // This only looks for the outside of shapes (not the holes inside)
            const has_contour_begun = // Look for an active pixel where...
                binary_image.pixels[current_pixel_index].value and
                // the previous pixel was inactive which indicates we're entering a shape
                (optional_last_pixel_index == null or !binary_image.pixels[optional_last_pixel_index.?].value);

            const already_seen_pixel_in_boundary = seen_boundary_points.get(ImagePoint{ .x = x, .y = y }) != null;

            // Whenever we enter an active shape, start tracing a contour
            if (has_contour_begun and
                // Skip if we've already seen this boundary point
                !already_seen_pixel_in_boundary)
            {
                start_point = ImagePoint{ .x = @intCast(x), .y = @intCast(y) };
                // We're scanning from the bottom going upwards, so the initial
                // direction is up
                start_direction = StepDirection.Up;

                const contour_boundary_points = switch (contour_method) {
                    .square => try squareContourTracing(
                        binary_image,
                        start_point,
                        start_direction,
                        allocator,
                    ),
                };

                try contours.append(contour_boundary_points);
                // Mark all of the boundary points as seen
                for (contour_boundary_points) |contour_boundary_point| {
                    try seen_boundary_points.put(contour_boundary_point, {});
                }
            }
        }
    }

    return contours.toOwnedSlice();
}

pub fn boundingRect() void {
    // TODO
}
