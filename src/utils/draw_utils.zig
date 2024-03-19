const std = @import("std");
const image_conversion = @import("../vision/image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const RGBPixel = image_conversion.RGBPixel;
const HSVImage = image_conversion.HSVImage;
const HSVPixel = image_conversion.HSVPixel;
const GrayscaleImage = image_conversion.GrayscaleImage;
const GrayscalePixel = image_conversion.GrayscalePixel;
const BinaryImage = image_conversion.BinaryImage;
const BinaryPixel = image_conversion.BinaryPixel;
const blackOutPixels = image_conversion.blackOutPixels;
const grayscaleToRgbImage = image_conversion.grayscaleToRgbImage;
const overlayImage = image_conversion.overlayImage;
const AnchorOriginX = image_conversion.AnchorOriginX;
const AnchorOriginY = image_conversion.AnchorOriginY;

fn PixelToImageType(comptime PixelType: type) type {
    return switch (PixelType) {
        RGBPixel => RGBImage,
        HSVPixel => HSVImage,
        GrayscalePixel => GrayscaleImage,
        BinaryPixel => BinaryImage,
        else => {
            @compileLog("PixelType=", @typeName(PixelType));
            @compileError("drawCross: Unsupported color pixel type");
        },
    };
}

/// Draws a solid rectangle unless `thickness` is greater than 0, in which case it draws
/// a inner border rectangle.
pub fn drawRectangle(
    width: usize,
    height: usize,
    thickness: usize,
    color: anytype,
    allocator: std.mem.Allocator,
) !PixelToImageType(@TypeOf(color)) {
    const PixelType = @TypeOf(color);
    const output_pixels = try allocator.alloc(PixelType, width * height);
    errdefer output_pixels.deinit(allocator);
    blackOutPixels(output_pixels);

    if (thickness == 0) {
        @memset(output_pixels, color);
    } else {
        for (0..thickness) |thickness_index| {
            // Draw the top border
            const top_row_start_index = thickness_index * width;
            @memset(output_pixels[top_row_start_index..(top_row_start_index + width)], color);

            // Draw the bottom border
            const bottom_row_start_index = ((height - 1) - thickness_index) * width;
            @memset(output_pixels[bottom_row_start_index..(bottom_row_start_index + width)], color);

            // Draw the left border
            for (0..height) |y| {
                const pixel_index = y * width + thickness_index;
                output_pixels[pixel_index] = color;
            }

            // Draw the right border
            for (0..height) |y| {
                const pixel_index = y * width + ((width - 1) - thickness_index);
                output_pixels[pixel_index] = color;
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

/// Draws a solid ellipse unless `thickness` is greater than 0, in which case it draws a
/// hollow ellipse/ring.
pub fn drawEllipse(
    width: usize,
    height: usize,
    thickness: usize,
    color: anytype,
    allocator: std.mem.Allocator,
) !PixelToImageType(@TypeOf(color)) {
    const PixelType = @TypeOf(color);
    const output_pixels = try allocator.alloc(PixelType, width * height);
    errdefer output_pixels.deinit(allocator);
    blackOutPixels(output_pixels);

    const center_x = width / 2;
    const center_y = height / 2;

    // The following implementation gives different results than OpenCV's
    // `cv.getStructuringElement(cv.MORPH_ELLIPSE, ...)` (OpenCV implementation:
    // https://github.com/opencv/opencv/blob/84bb1cda4ea6135d9eb915e9ae2e348e858cc1f2/modules/imgproc/src/morph.dispatch.cpp#L135-L186)
    //
    // Based on https://stackoverflow.com/questions/59971407/how-can-i-test-if-a-point-is-in-an-ellipse/65601453#65601453
    const radius_x = center_x;
    const radius_y = center_y;
    const squared_radius = radius_x * radius_x;
    const squared_inner_radius = blk: {
        if (thickness > 0) {
            break :blk (radius_x - thickness) * (radius_x - thickness);
        }

        break :blk 0;
    };

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
            if (squared_distance <= squared_radius and
                // Ring/hollow-circle condition
                (squared_inner_radius == 0 or squared_distance > squared_inner_radius))
            {
                output_pixels[pixel_index] = color;
            }
        }
    }

    return .{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

pub fn drawCross(
    width: usize,
    height: usize,
    color: anytype,
    allocator: std.mem.Allocator,
) !PixelToImageType(@TypeOf(color)) {
    const PixelType = @TypeOf(color);
    const output_pixels = try allocator.alloc(PixelType, width * height);
    errdefer output_pixels.deinit(allocator);
    blackOutPixels(output_pixels);

    const center_x = width / 2;
    const center_y = height / 2;

    // Set the center row
    const row_start_index = center_y * width;
    for (0..width) |x| {
        const pixel_index = row_start_index + x;
        output_pixels[pixel_index] = color;
    }

    // Set the center column
    for (0..height) |y| {
        const pixel_index = y * width + center_x;
        output_pixels[pixel_index] = color;
    }

    return .{
        .width = width,
        .height = height,
        .pixels = output_pixels,
    };
}

pub fn drawRectangleOnImage(
    image: anytype,
    width: usize,
    height: usize,
    thickness: usize,
    color: anytype,
    image_position_x: usize,
    image_position_y: usize,
    image_origin_x: AnchorOriginX,
    image_origin_y: AnchorOriginY,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    const rect_image = try drawRectangle(
        width,
        height,
        thickness,
        color,
        allocator,
    );
    defer rect_image.deinit(allocator);

    const marked_image = try overlayImage(
        rect_image,
        image,
        image_position_x,
        image_position_y,
        image_origin_x,
        image_origin_y,
        allocator,
    );

    return marked_image;
}

pub fn drawEllipseOnImage(
    image: anytype,
    width: usize,
    height: usize,
    thickness: usize,
    color: anytype,
    image_position_x: usize,
    image_position_y: usize,
    image_origin_x: AnchorOriginX,
    image_origin_y: AnchorOriginY,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    const ellipse_image = try drawEllipse(
        width,
        height,
        thickness,
        color,
        allocator,
    );
    defer ellipse_image.deinit(allocator);

    const marked_image = try overlayImage(
        ellipse_image,
        image,
        image_position_x,
        image_position_y,
        image_origin_x,
        image_origin_y,
        allocator,
    );

    return marked_image;
}

pub fn drawCrossOnImage(
    image: anytype,
    width: usize,
    height: usize,
    color: anytype,
    image_position_x: usize,
    image_position_y: usize,
    image_origin_x: AnchorOriginX,
    image_origin_y: AnchorOriginY,
    allocator: std.mem.Allocator,
) !@TypeOf(image) {
    const cross_image = try drawCross(
        width,
        height,
        color,
        allocator,
    );
    defer cross_image.deinit(allocator);

    const marked_image = try overlayImage(
        cross_image,
        image,
        image_position_x,
        image_position_y,
        image_origin_x,
        image_origin_y,
        allocator,
    );

    return marked_image;
}
