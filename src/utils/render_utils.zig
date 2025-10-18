const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");

pub const Dimensions = struct {
    width: i16,
    height: i16,
};

pub fn BoundingClientRect(comptime NumberType: type) type {
    return struct {
        x: NumberType,
        y: NumberType,
        width: NumberType,
        height: NumberType,

        pub fn top(self: @This()) NumberType {
            return self.y;
        }
        pub fn left(self: @This()) NumberType {
            return self.x;
        }
        pub fn bottom(self: @This()) NumberType {
            return self.y + self.height;
        }
        pub fn right(self: @This()) NumberType {
            return self.x + self.width;
        }
        pub fn centerX(self: @This()) NumberType {
            return self.x + self.width / 2;
        }
        pub fn centerY(self: @This()) NumberType {
            return self.y + self.height / 2;
        }
    };
}

/// Find the intersection region between two BoundingClientRect's.
pub fn findIntersection(rect1: anytype, rect2: @TypeOf(rect1)) ?@TypeOf(rect1) {
    const pos_x = @max(rect1.left(), rect2.left());
    const x_overlap = blk: {
        const min_right = @min(rect1.right(), rect2.right());
        if (min_right > pos_x) {
            break :blk min_right - pos_x;
        }

        break :blk 0;
    };
    const pos_y = @max(rect1.top(), rect2.top());
    const y_overlap = blk: {
        const min_bottom = @min(rect1.bottom(), rect2.bottom());
        if (min_bottom > pos_y) {
            break :blk min_bottom - pos_y;
        }

        break :blk 0;
    };

    if (x_overlap > 0 and y_overlap > 0) {
        return .{
            .x = pos_x,
            .y = pos_y,
            .width = x_overlap,
            .height = y_overlap,
        };
    }

    return null;
}

test "findIntersection" {
    // Intersection
    try std.testing.expectEqual(findIntersection(
        BoundingClientRect(f32){
            .x = 1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
        BoundingClientRect(f32){
            .x = 2,
            .y = 2,
            .width = 2.0,
            .height = 2.0,
        },
    ), .{
        .x = 2.0,
        .y = 2.0,
        .width = 1.0,
        .height = 1.0,
    });

    // No intersection
    try std.testing.expectEqual(findIntersection(
        BoundingClientRect(f32){
            .x = 1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
        BoundingClientRect(f32){
            .x = 6.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
    ), null);

    // No intersection (usize)
    try std.testing.expectEqual(findIntersection(
        BoundingClientRect(usize){
            .x = 1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
        BoundingClientRect(usize){
            .x = 6.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
    ), null);
}

pub const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

pub const XOriginKeyword = enum {
    left,
    center,
    right,
};

pub const YOriginKeyword = enum {
    top,
    center,
    bottom,
};

fn xOriginKeywordToLengthPercentage(keyword: XOriginKeyword) f32 {
    switch (keyword) {
        XOriginKeyword.left => return 0.0,
        XOriginKeyword.center => return 0.5,
        XOriginKeyword.right => return 1.0,
    }
}

fn yOriginKeywordToLengthPercentage(keyword: YOriginKeyword) f32 {
    switch (keyword) {
        YOriginKeyword.top => return 0.0,
        YOriginKeyword.center => return 0.5,
        YOriginKeyword.bottom => return 1.0,
    }
}

pub const OriginValue = union(enum) {
    /// Percentage value from 0.0 to 1.0
    relative: f32,
    /// Absolute value in pixels
    absolute: i16,
};

pub const PositionOrigin = struct {
    x: OriginValue,
    y: OriginValue,

    pub fn init(x_origin: union(enum) {
        keyword: XOriginKeyword,
        relative: f32,
        absolute: i16,
    }, y_origin: union(enum) {
        keyword: YOriginKeyword,
        relative: f32,
        absolute: i16,
    }) @This() {
        return .{
            .x = switch (x_origin) {
                .keyword => OriginValue{ .relative = xOriginKeywordToLengthPercentage(x_origin.keyword) },
                .relative => OriginValue{ .relative = x_origin.relative },
                .absolute => OriginValue{ .absolute = x_origin.absolute },
            },
            .y = switch (y_origin) {
                .keyword => OriginValue{ .relative = yOriginKeywordToLengthPercentage(y_origin.keyword) },
                .relative => OriginValue{ .relative = y_origin.relative },
                .absolute => OriginValue{ .absolute = y_origin.absolute },
            },
        };
    }
};

fn computeOffsetFromOrigin(length: i16, origin: OriginValue) i16 {
    var result: i16 = 0;
    switch (origin) {
        OriginValue.relative => |percentage| {
            result = @intFromFloat(@round(
                @as(f32, @floatFromInt(length)) * percentage,
            ));
        },
        OriginValue.absolute => |offset| {
            result += offset;
        },
    }

    return result;
}

pub fn renderString(
    x_connection: common.XConnection,
    drawable_id: u32,
    fg_gc_id: u32,
    font_dims: FontDims,
    position_x: i16,
    position_y: i16,
    position_origin: PositionOrigin,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);

    const text_width: i16 = @intCast(font_dims.width * text_len);

    // Calculate the baseline position of the text
    const baseline_x = position_x - computeOffsetFromOrigin(text_width, position_origin.x) + font_dims.font_left;
    const baseline_y = position_y - computeOffsetFromOrigin(font_dims.height, position_origin.y) + font_dims.font_ascent;

    x.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = fg_gc_id,
        .x = baseline_x,
        .y = baseline_y,
    });
    try x_connection.send(msg[0..x.image_text8.getLen(text_len)]);
}
