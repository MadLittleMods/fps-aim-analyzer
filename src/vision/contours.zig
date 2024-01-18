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

/// Image coordinate system that allows out of bounds coordinates.
/// Top-left is (0, 0),bottom-right is (width, height).
const CanvasPoint = struct {
    x: isize,
    y: isize,

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

/// Can only find the outer contour of 4-connected pixels (pixels that are connected by
/// their edges)
///
/// Square tracing algorithm:
///  - Every time you find yourself standing on a black pixel, turn left, and
///  - Every time you find yourself standing on a white pixel, turn right,
///  - until you meet the stop criteria
///
/// https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
/// https://en.wikipedia.org/wiki/Boundary_tracing#Square_tracing_algorithm
pub fn squareContourTracing(binary_image: BinaryImage, allocator: std.mem.Allocator) ![]const ImagePoint {
    // Find the starting point
    //
    // Starting from the left-most column, scan bottom-up until we find the first active
    // pixel
    var start_point: CanvasPoint = undefined;
    var start_direction: StepDirection = undefined;
    // Start from the left-most column
    outer: for (0..binary_image.width) |x| {
        // Scan bottom-up
        var y = binary_image.height - 1;
        while (y > 0) : (y -%= 1) {
            const current_pixel_index = (y * binary_image.width) + x;

            if (binary_image.pixels[current_pixel_index].value) {
                start_point = CanvasPoint{ .x = @intCast(x), .y = @intCast(y) };
                // We're scanning from the bottom going upwards, so the initial
                // direction is up
                start_direction = StepDirection.Up;
                break :outer;
            }
        }
    }

    // We use a hash map to avoid duplicates
    var boundary_points = std.AutoArrayHashMap(ImagePoint, void).init(allocator);
    defer boundary_points.deinit();
    // We found at least one active pixel
    try boundary_points.put(ImagePoint.fromCanvasPoint(start_point), {});

    // The first pixel you encounter is a white one by definition, so we go left
    var current_direction = _turnLeft(start_direction);
    var current_point: CanvasPoint = CanvasPoint.stepInDirection(
        start_point,
        current_direction,
    );

    // Jacob's stopping criterion: Stop after entering the start pixel a second time in
    // the same direction you entered it initially
    while (!(std.meta.eql(current_point, start_point) and std.meta.eql(current_direction, start_direction))) {
        const optional_current_pixel_index: ?usize = blk: {
            const current_image_point = ImagePoint.fromCanvasPoint(current_point);
            const is_current_point_in_image_bounds = current_point.x >= 0 or
                current_point.x < binary_image.width or
                current_point.y >= 0 or
                current_point.y < binary_image.height;

            if (is_current_point_in_image_bounds) {
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

test "squareContourTracing" {
    const allocator = std.testing.allocator;

    // Simple rectangle
    try _testSquareContourTracing(
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
        &[_]ImagePoint{
            .{ .x = 2, .y = 4 },
            .{ .x = 2, .y = 3 },
            .{ .x = 2, .y = 2 },
            .{ .x = 2, .y = 1 },
            .{ .x = 3, .y = 1 },
            .{ .x = 4, .y = 1 },
            .{ .x = 4, .y = 2 },
            .{ .x = 4, .y = 3 },
            .{ .x = 4, .y = 4 },
            .{ .x = 3, .y = 4 },
        },
        allocator,
    );

    // Complex shape from the "Demonstration" section on
    // https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
    try _testSquareContourTracing(
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
        &[_]ImagePoint{
            .{ .x = 2, .y = 5 },
            .{ .x = 2, .y = 4 },
            .{ .x = 3, .y = 3 },
            // TODO: Not sure if this point should be included
            .{ .x = 3, .y = 2 },
            .{ .x = 2, .y = 2 },
            .{ .x = 3, .y = 1 },
            .{ .x = 4, .y = 2 },
            .{ .x = 4, .y = 3 },
            .{ .x = 3, .y = 4 },
        },
        allocator,
    );

    // Test Jacob's stopping criterion.
    // Example is from the "The Stopping Criterion" section on
    // https://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/square.html
    try _testSquareContourTracing(
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
        &[_]ImagePoint{
            .{ .x = 2, .y = 5 },
            .{ .x = 2, .y = 4 },
            .{ .x = 3, .y = 5 },
            .{ .x = 4, .y = 4 },
            .{ .x = 4, .y = 3 },
            .{ .x = 3, .y = 2 },
            .{ .x = 3, .y = 1 },
            .{ .x = 4, .y = 2 },
            .{ .x = 5, .y = 1 },
            .{ .x = 5, .y = 2 },
            .{ .x = 6, .y = 3 },
            .{ .x = 5, .y = 4 },
            .{ .x = 6, .y = 5 },
            .{ .x = 4, .y = 5 },
        },
        allocator,
    );
}

fn _testSquareContourTracing(
    binary_image: BinaryImage,
    expected_contour_boundary: []const ImagePoint,
    allocator: std.mem.Allocator,
) !void {
    const actual_contour_boundary = try squareContourTracing(binary_image, allocator);
    defer allocator.free(actual_contour_boundary);
    try _expectContourEqual(
        binary_image,
        actual_contour_boundary,
        expected_contour_boundary,
        allocator,
    );
}

/// Trace the contour on the image with red pixels
fn _traceContourOnRgbImage(
    binary_image: BinaryImage,
    contour_boundary: []const ImagePoint,
    allocator: std.mem.Allocator,
) !RGBImage {
    const rgb_image = try binaryToRgbImage(binary_image, allocator);
    defer rgb_image.deinit(allocator);
    var mutable_pixels = try allocator.alloc(RGBPixel, rgb_image.pixels.len);
    std.mem.copyForwards(RGBPixel, mutable_pixels, rgb_image.pixels);

    for (contour_boundary) |contour_point| {
        const pixel_index = (contour_point.y * rgb_image.width) + contour_point.x;
        mutable_pixels[pixel_index] = .{ .r = 1.0, .g = 0, .b = 0 };
    }

    return .{
        .width = rgb_image.width,
        .height = rgb_image.height,
        .pixels = mutable_pixels,
    };
}

fn _expectContourEqual(
    binary_image: BinaryImage,
    actual_contour_boundary: []const ImagePoint,
    expected_contour_boundary: []const ImagePoint,
    allocator: std.mem.Allocator,
) !void {
    std.testing.expectEqualSlices(
        ImagePoint,
        expected_contour_boundary,
        actual_contour_boundary,
    ) catch |err| {
        const actual_rgb_image = try _traceContourOnRgbImage(
            binary_image,
            actual_contour_boundary,
            allocator,
        );
        defer actual_rgb_image.deinit(allocator);
        try printLabeledImage(
            "Actual contour",
            actual_rgb_image,
            .full_block,
            allocator,
        );

        const expected_rgb_image = try _traceContourOnRgbImage(
            binary_image,
            expected_contour_boundary,
            allocator,
        );
        defer expected_rgb_image.deinit(allocator);
        try printLabeledImage(
            "Expected contour",
            expected_rgb_image,
            .full_block,
            allocator,
        );

        return err;
    };
}

// Moore Boundary Tracing algorithm, Moore-Neighbor Tracing
pub fn mooreContourTracing(binary_image: BinaryImage, allocator: std.mem.Allocator) void {
    _ = allocator;
    _ = binary_image;
    // TODO
}

pub fn findContours(binary_image: BinaryImage, allocator: std.mem.Allocator) void {
    _ = allocator;
    _ = binary_image;
    // TODO
}

pub fn boundingRect() void {
    // TODO
}
