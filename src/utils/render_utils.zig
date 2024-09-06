const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");

pub fn Coordinate(comptime NumberType: type) type {
    return struct {
        x: NumberType,
        y: NumberType,
    };
}

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

pub fn renderString(
    sock: std.os.socket_t,
    drawable_id: u32,
    fg_gc_id: u32,
    pos_x: i16,
    pos_y: i16,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
    x.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = fg_gc_id,
        .x = pos_x,
        .y = pos_y,
    });
    try common.send(sock, msg[0..x.image_text8.getLen(text_len)]);
}
